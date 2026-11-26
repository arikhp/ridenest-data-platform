"""RideNest mock data generator (v2: seasonality, weather, growth, churn).

Writes, for each day in the range:
  * Azure SQL  billing.riders / billing.payments / billing.promo_codes   (the "billing DB" source)
  * ADLS landing/trips/yyyy/mm/dd/trip_events_<yyyymmdd>_<part>.json     (NDJSON app events)
  * ADLS landing/fleet/yyyy/mm/dd/vehicles.csv + maintenance.csv         (fleet export)
  * ADLS landing/reference/zones.csv + pricing.csv                       (static reference)

Profiles:
  dev   7 days,   5k riders,  600 vehicles  (~1.5k trips/day)
  full  365 days, 50k riders, ~1.2k -> 2k vehicles (~4-9k trips/day)  ~= 5-6M events, ~2.5M payments

Realism: summer peak / winter dip per city, rainy days (-45%), Fri-Sun +20%, fleet + rider growth,
rider churn, heavy-user skew (Pareto-ish activity weights).

Deliberate data-quality issues for the silver layer to handle:
  ~1% duplicated events, ~0.5% GPS at (0,0), ~0.3% trips ending before they start,
  local-time timestamps with offsets (silver normalises to UTC), ~2% failed payments.

Idempotent: re-running a date overwrites its files and replaces that day's payments (by payment_id);
`--truncate` (default for the full profile) empties billing.payments first.
Auth: your `az login` identity (lake: Storage Blob Data Contributor; Key Vault: Secrets Officer; RG Owner/Contributor
to open a temporary SQL firewall rule "generator-temp" for your current IP, removed again on exit).
"""
from __future__ import annotations

import argparse, contextlib, csv, hashlib, io, itertools, json, math, random, subprocess, time, urllib.request, uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from zoneinfo import ZoneInfo

import pymssql
from azure.identity import AzureCliCredential
from azure.keyvault.secrets import SecretClient
from azure.storage.filedatalake import DataLakeServiceClient
from faker import Faker

# --------------------------------------------------------------------------- reference data
CITIES = {
    #       seasonal amplitude: how much summer beats winter; rain_* = rain probability winter/summer
    "TLV": dict(name="Tel Aviv", tz="Asia/Jerusalem", lat=32.0853, lon=34.7818, currency="ILS",
                unlock=5.0, per_min=0.90, locale="he_IL", weight=0.40, season_amp=0.20, rain_w=0.30, rain_s=0.01),
    "BER": dict(name="Berlin", tz="Europe/Berlin", lat=52.5200, lon=13.4050, currency="EUR",
                unlock=1.0, per_min=0.25, locale="de_DE", weight=0.35, season_amp=0.45, rain_w=0.35, rain_s=0.25),
    "LIS": dict(name="Lisbon", tz="Europe/Lisbon", lat=38.7223, lon=-9.1393, currency="EUR",
                unlock=1.0, per_min=0.20, locale="pt_PT", weight=0.25, season_amp=0.30, rain_w=0.40, rain_s=0.03),
}
ZONE_NAMES = {
    "TLV": ["Old North", "Rothschild", "Jaffa", "Florentin", "Ramat Aviv"],
    "BER": ["Mitte", "Kreuzberg", "Prenzlauer Berg", "Friedrichshain", "Charlottenburg"],
    "LIS": ["Baixa", "Alfama", "Bairro Alto", "Belem", "Parque das Nacoes"],
}
MODELS = [("Nimbus S2", "scooter"), ("Nimbus S3", "scooter"), ("Volt E1", "ebike")]
PROMOS = [("WELCOME20", 20, "2025-01-01", "2027-12-31"), ("BERLIN10", 10, "2026-09-01", "2026-12-31"),
          ("SUMMERTLV", 15, "2026-06-01", "2026-09-30")]
# history_end anchors the initial history: fleet growth and the base rider pool are computed from this
# fixed window, so re-running any day (or running one new day) reproduces exactly the same world.
# After history_end, `new_riders_per_day` riders sign up every day (the company keeps growing).
PROFILES = {
    "dev":  dict(days=7,   riders=5_000,  vehicles=600,   trips_per_vehicle=2.6, fleet_start_share=1.0,
                 history_end=date(2026, 11, 24), new_riders_per_day=10),
    "full": dict(days=365, riders=50_000, vehicles=2_000, trips_per_vehicle=3.6, fleet_start_share=0.6,
                 history_end=date(2026, 11, 25), new_riders_per_day=70),
}
PAYMENT_COLS = ["payment_id", "rider_id", "trip_id", "amount", "currency", "method", "status", "promo_code", "paid_at"]
RIDER_COLS = ["rider_id", "full_name", "email", "phone", "home_city", "signup_at", "plan", "marketing_opt_in"]


@dataclass
class Zone:
    zone_id: str
    city: str
    name: str
    lat: float
    lon: float


def build_zones(rng: random.Random) -> list[Zone]:
    return [Zone(f"{code}-Z{i+1}", code, n,
                 round(c["lat"] + rng.uniform(-0.03, 0.03), 5), round(c["lon"] + rng.uniform(-0.04, 0.04), 5))
            for code, c in CITIES.items() for i, n in enumerate(ZONE_NAMES[code])]


# --------------------------------------------------------------------------- helpers
def sh(*cmd: str) -> str:
    return subprocess.check_output(cmd, text=True).strip()


def jitter(rng, lat, lon, km=0.6):
    return (round(lat + rng.uniform(-km, km) / 111, 6),
            round(lon + rng.uniform(-km, km) / (111 * math.cos(math.radians(lat))), 6))


def start_hour(rng) -> float:
    r = rng.random()  # commute peaks 08:30 and 18:00 local + flat daytime base
    if r < 0.30:
        return min(23.9, max(0, rng.gauss(8.5, 1.0)))
    if r < 0.65:
        return min(23.9, max(0, rng.gauss(18.0, 1.5)))
    return rng.uniform(7, 23.5)


def summer_index(d: date) -> float:
    """+1 around mid-July, -1 around mid-January."""
    return math.cos(2 * math.pi * (d.timetuple().tm_yday - 196) / 365.25)


# --------------------------------------------------------------------------- generator
class Generator:
    def __init__(self, args, start: date, end: date):
        self.args, self.start, self.end = args, start, end
        prof = PROFILES[args.profile]
        self.hist_end = prof["history_end"]
        self.hist_start = self.hist_end - timedelta(days=prof["days"] - 1)
        self.new_riders_per_day = prof["new_riders_per_day"]
        self.rng = random.Random(args.seed)
        self.zones = build_zones(self.rng)
        self.zones_by_city = {c: [z for z in self.zones if z.city == c] for c in CITIES}
        self.riders = self._riders()
        self.vehicles = self._vehicles()

    def _riders(self):
        rng, out = random.Random(self.args.seed + 1), []
        codes, weights = list(CITIES), [c["weight"] for c in CITIES.values()]
        fakers = {c: Faker(CITIES[c]["locale"]) for c in CITIES}
        for f in fakers.values():
            f.seed_instance(self.args.seed)
        span = (self.hist_end - date(2024, 11, 1)).days  # fixed window, independent of this run
        for i in range(self.args.riders):
            city = rng.choices(codes, weights)[0]
            f = fakers[city]
            # growth: signups skew towards recent dates (sqrt -> more density later)
            signup = datetime(2024, 11, 1) + timedelta(days=span * math.sqrt(rng.random()), minutes=rng.randint(0, 1439))
            out.append(dict(
                rider_id=f"R{i+1:07d}", full_name=f.name(),
                email=f"rider{i+1}@example.{'co.il' if city == 'TLV' else 'eu'}",
                phone=f.phone_number()[:30], home_city=city, signup_at=signup,
                plan=rng.choices(["pay_as_you_go", "monthly_pass", "student"], [0.75, 0.18, 0.07])[0],
                marketing_opt_in=1 if rng.random() < 0.4 else 0,
                # not written to SQL: drive behaviour
                _activity=rng.paretovariate(1.6),
                _churn=(signup + timedelta(days=rng.expovariate(1 / 240))).date(),
            ))
        # Growth after the initial history: new sign-ups each day, deterministic per day.
        n, d = len(out), self.hist_end + timedelta(days=1)
        while d <= self.end:
            drng = random.Random(f"{self.args.seed}-signups-{d.isoformat()}")
            for _ in range(self.new_riders_per_day):
                n += 1
                city = drng.choices(codes, weights)[0]
                f = Faker(CITIES[city]["locale"])
                f.seed_instance(f"{self.args.seed}-{n}")
                signup = datetime.combine(d, datetime.min.time()) + timedelta(minutes=drng.randint(0, 1439))
                out.append(dict(
                    rider_id=f"R{n:07d}", full_name=f.name(),
                    email=f"rider{n}@example.{'co.il' if city == 'TLV' else 'eu'}",
                    phone=f.phone_number()[:30], home_city=city, signup_at=signup,
                    plan=drng.choices(["pay_as_you_go", "monthly_pass", "student"], [0.75, 0.18, 0.07])[0],
                    marketing_opt_in=1 if drng.random() < 0.4 else 0,
                    _activity=drng.paretovariate(1.6),
                    _churn=(signup + timedelta(days=drng.expovariate(1 / 240))).date(),
                ))
            d += timedelta(days=1)
        return out

    def _vehicles(self):
        rng, out = random.Random(self.args.seed + 2), []
        codes, weights = list(CITIES), [c["weight"] for c in CITIES.values()]
        n0 = int(self.args.vehicles * self.args.fleet_start_share)
        total_days = max(1, (self.hist_end - self.hist_start).days)  # fleet grows over the fixed history window
        for i in range(self.args.vehicles):
            city = rng.choices(codes, weights)[0]
            model, vtype = rng.choices(MODELS, [0.45, 0.35, 0.20])[0]
            commissioned = (self.hist_start - timedelta(days=rng.randint(30, 600)) if i < n0
                            else self.hist_start + timedelta(days=int(total_days * (i - n0) / max(1, self.args.vehicles - n0))))
            out.append(dict(vehicle_id=f"V{i+1:05d}", model=model, vehicle_type=vtype, city=city,
                            home_zone_id=rng.choice(self.zones_by_city[city]).zone_id, commissioned_on=commissioned))
        return out

    # ----- one day -----
    def day(self, d: date):
        rng = random.Random(f"{self.args.seed}-{d.isoformat()}")
        events, payments, fleet, maint = [], [], [], []
        weekend = d.weekday() >= 4  # Fri/Sat/Sun busier

        for city, c in CITIES.items():
            riders = [r for r in self.riders if r["home_city"] == city and r["signup_at"].date() <= d < r["_churn"]]
            vehicles = [v for v in self.vehicles if v["city"] == city and v["commissioned_on"] <= d]
            if not riders or not vehicles:
                continue
            s = summer_index(d)
            rain_p = c["rain_w"] + (c["rain_s"] - c["rain_w"]) * (s + 1) / 2
            rainy = rng.random() < rain_p
            factor = (1 + c["season_amp"] * s) * (1.2 if weekend else 1.0) * (0.55 if rainy else 1.0) * rng.uniform(0.92, 1.08)
            n_trips = int(len(vehicles) * self.args.trips_per_vehicle * factor)
            cum = list(itertools.accumulate(r["_activity"] for r in riders))
            chosen = rng.choices(riders, cum_weights=cum, k=n_trips)
            tz = ZoneInfo(c["tz"])
            for rider in chosen:
                veh = rng.choice(vehicles)
                start = datetime.combine(d, datetime.min.time(), tz) + timedelta(hours=start_hour(rng))
                minutes = max(1.0, rng.lognormvariate(2.35, 0.5) * (0.85 if rainy else 1.0))
                end = start + timedelta(minutes=minutes)
                z1, z2 = rng.choice(self.zones_by_city[city]), rng.choice(self.zones_by_city[city])
                s_lat, s_lon = jitter(rng, z1.lat, z1.lon)
                e_lat, e_lon = jitter(rng, z2.lat, z2.lon)
                trip_id = str(uuid.UUID(int=rng.getrandbits(128)))
                battery = rng.randint(25, 100)
                promo = rng.choice(PROMOS) if rng.random() < 0.08 else None
                fare = c["unlock"] + c["per_min"] * math.ceil(minutes)
                if promo:
                    fare *= 1 - promo[1] / 100
                fare = round(fare, 2)
                if rng.random() < 0.003:            # clock skew: ended before started
                    end = start - timedelta(minutes=rng.randint(1, 5))
                if rng.random() < 0.005:            # GPS dropout
                    e_lat, e_lon = 0.0, 0.0
                base = dict(trip_id=trip_id, rider_id=rider["rider_id"], vehicle_id=veh["vehicle_id"], city=city)
                events.append(dict(event_id=str(uuid.UUID(int=rng.getrandbits(128))), event_type="trip_started",
                                   ts=start.isoformat(timespec="seconds"), lat=s_lat, lon=s_lon, battery_pct=battery, **base))
                ended = dict(event_id=str(uuid.UUID(int=rng.getrandbits(128))), event_type="trip_ended",
                             ts=end.isoformat(timespec="seconds"), lat=e_lat, lon=e_lon,
                             battery_pct=max(0, battery - int(minutes * 0.8)),
                             distance_m=int(minutes * rng.uniform(180, 320)), fare_amount=fare, currency=c["currency"],
                             app_version=rng.choice(["5.2.0", "5.3.1", "5.4.0"]), **base)
                events.append(ended)
                if rng.random() < 0.01:             # duplicate delivery
                    events.append(dict(ended))
                payments.append((
                    str(uuid.UUID(int=rng.getrandbits(128))), rider["rider_id"], trip_id, Decimal(f"{fare:.2f}"), c["currency"],
                    rng.choices(["card", "apple_pay", "google_pay", "wallet"], [0.5, 0.25, 0.15, 0.1])[0],
                    rng.choices(["succeeded", "failed", "refunded"], [0.97, 0.02, 0.01])[0],
                    promo[0] if promo else None,
                    (max(start, end) + timedelta(seconds=rng.randint(5, 90))).astimezone(timezone.utc).replace(tzinfo=None),
                ))
            for v in vehicles:  # end-of-day fleet snapshot + maintenance tickets
                status = rng.choices(["available", "in_use", "charging", "maintenance", "retired"], [0.70, 0.08, 0.12, 0.08, 0.02])[0]
                fleet.append(dict(v, battery_pct=rng.randint(5, 100), status=status,
                                  last_service_on=d - timedelta(days=rng.randint(0, 120)), snapshot_date=d))
                if rng.random() < (0.016 if rainy else 0.010):
                    opened = datetime.combine(d, datetime.min.time()) + timedelta(hours=rng.uniform(6, 20))
                    maint.append(dict(ticket_id=f"M{d:%Y%m%d}-{v['vehicle_id']}", vehicle_id=v["vehicle_id"],
                                      opened_at=opened.isoformat(timespec="minutes"),
                                      closed_at=(opened + timedelta(hours=rng.uniform(2, 72))).isoformat(timespec="minutes"),
                                      issue=rng.choice(["flat_tyre", "brake_wear", "battery_fault", "vandalism", "display_error"]),
                                      cost_eur=round(rng.uniform(15, 220), 2)))
        rng.shuffle(events)
        return events, payments, fleet, maint


# --------------------------------------------------------------------------- sinks
def csv_bytes(rows: list[dict]) -> bytes:
    buf = io.StringIO()
    if rows:
        w = csv.DictWriter(buf, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    return buf.getvalue().encode()


class Lake:
    def __init__(self, account: str, cred):
        svc = DataLakeServiceClient(f"https://{account}.dfs.core.windows.net", credential=cred)
        self.fs = svc.get_file_system_client("landing")

    def put(self, path: str, data: bytes):
        for attempt in range(5):
            try:
                return self.fs.get_file_client(path).upload_data(data, overwrite=True)
            except Exception:
                if attempt == 4:
                    raise
                time.sleep(2 ** attempt)


DDL = """
IF SCHEMA_ID('billing') IS NULL EXEC('CREATE SCHEMA billing');
IF OBJECT_ID('billing.riders') IS NULL CREATE TABLE billing.riders (
  rider_id varchar(12) PRIMARY KEY, full_name nvarchar(100), email varchar(200), phone varchar(30),
  home_city char(3), signup_at datetime2(0), [plan] varchar(20), marketing_opt_in bit,
  updated_at datetime2(0) DEFAULT SYSUTCDATETIME());
IF OBJECT_ID('billing.promo_codes') IS NULL CREATE TABLE billing.promo_codes (
  code varchar(20) PRIMARY KEY, discount_pct int, valid_from date, valid_to date);
IF OBJECT_ID('billing.payments') IS NULL CREATE TABLE billing.payments (
  payment_id varchar(36) PRIMARY KEY, rider_id varchar(12), trip_id varchar(36), amount decimal(10,2),
  currency char(3), method varchar(20), status varchar(12), promo_code varchar(20) NULL,
  paid_at datetime2(0), loaded_at datetime2(0) DEFAULT SYSUTCDATETIME());
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='ix_payments_paid_at')
  CREATE INDEX ix_payments_paid_at ON billing.payments(paid_at);
"""


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--env", default="dev", choices=["dev", "preprod", "prod"])
    p.add_argument("--profile", default="dev", choices=list(PROFILES))
    p.add_argument("--end", type=date.fromisoformat, default=date.today() - timedelta(days=1), help="last day (inclusive)")
    p.add_argument("--days", type=int)
    p.add_argument("--riders", type=int)
    p.add_argument("--vehicles", type=int)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--truncate", action=argparse.BooleanOptionalAction, default=None,
                   help="empty billing.payments first (default: only for a full-history run)")
    p.add_argument("--skip-lake", action="store_true",
                   help="only (re)write Azure SQL; the lake files are deterministic and already there")
    p.add_argument("--subscription-id", default=None)
    args = p.parse_args()
    prof = PROFILES[args.profile]
    for k in ("days", "riders", "vehicles"):
        if getattr(args, k) is None:
            setattr(args, k, prof[k])
    args.trips_per_vehicle, args.fleet_start_share = prof["trips_per_vehicle"], prof["fleet_start_share"]

    sub = args.subscription_id or sh("az", "account", "show", "--query", "id", "-o", "tsv")
    sfx = hashlib.sha1(sub.encode()).hexdigest()[:6]
    server = f"sql-ridenest-{args.env}-{sfx}"
    with temporary_firewall_rule(server):
        run(args, sfx, server)


@contextlib.contextmanager
def temporary_firewall_rule(server: str):
    """Open the SQL firewall for this machine's current public IP, and always close it again.
    Avoids hard-coding a (changing) home IP in Terraform."""
    ip = urllib.request.urlopen("https://api.ipify.org", timeout=15).read().decode().strip()
    rule = "generator-temp"
    print(f"opening SQL firewall for {ip} on {server}", flush=True)
    sh("az", "sql", "server", "firewall-rule", "create", "-g", "rg-ridenest-ilc", "-s", server, "-n", rule,
       "--start-ip-address", ip, "--end-ip-address", ip, "-o", "none")
    try:
        yield
    finally:
        sh("az", "sql", "server", "firewall-rule", "delete", "-g", "rg-ridenest-ilc", "-s", server, "-n", rule)
        print(f"closed SQL firewall rule {rule}", flush=True)


def run(args, sfx: str, server: str):
    start = args.end - timedelta(days=args.days - 1)
    # Only a full-history run empties payments; daily runs replace their own day's payments by id.
    truncate = (args.days >= PROFILES[args.profile]["days"]) if args.truncate is None else args.truncate
    cred = AzureCliCredential()
    lake = Lake(f"stridenest{args.env}{sfx}", cred)
    kv = SecretClient(f"https://kv-ridenest-{args.env}-{sfx[:4]}.vault.azure.net", credential=cred)
    conn = pymssql.connect(server=f"{server}.database.windows.net", user="ridenestadmin",
                           password=kv.get_secret("sql-admin-password").value, database="sqldb-billing",
                           tds_version="7.4", login_timeout=120, timeout=600)
    conn.autocommit(False)
    cur = conn.cursor()

    t0 = time.time()
    gen = Generator(args, start, args.end)
    print(f"[{args.env}/{args.profile}] {start}..{args.end}  riders={len(gen.riders)} vehicles={len(gen.vehicles)} "
          f"truncate={truncate}", flush=True)

    put = (lambda path, data: None) if args.skip_lake else lake.put
    put("reference/zones.csv", csv_bytes([vars(z) for z in gen.zones]))
    put("reference/pricing.csv", csv_bytes([dict(city=k, city_name=c["name"], currency=c["currency"],
                                                 unlock_fee=c["unlock"], per_minute=c["per_min"]) for k, c in CITIES.items()]))
    for stmt in DDL.split(";\n"):
        if stmt.strip():
            cur.execute(stmt)
    cur.execute("DELETE FROM billing.promo_codes")
    for code, pct, vf, vt in PROMOS:
        cur.execute("INSERT INTO billing.promo_codes VALUES (%s,%s,%s,%s)", (code, pct, vf, vt))
    cur.execute("SELECT COUNT(*) FROM billing.riders")
    if cur.fetchone()[0] != len(gen.riders):
        cur.execute("TRUNCATE TABLE billing.riders")
        conn.commit()
        conn.bulk_copy("billing.riders", [tuple(r[c] for c in RIDER_COLS) for r in gen.riders],
                       column_ids=list(range(1, len(RIDER_COLS) + 1)), batch_size=10_000)
        conn.commit()  # autocommit is off: an uncommitted bulk copy is rolled back on close
    if truncate:
        cur.execute("TRUNCATE TABLE billing.payments")
    conn.commit()

    totals = dict(events=0, payments=0, fleet=0, maint=0)
    pending: list[tuple] = []
    pool = ThreadPoolExecutor(max_workers=8)
    futures = []
    for i in range(args.days):
        d = start + timedelta(days=i)
        events, payments, fleet, maint = gen.day(d)
        part, chunks = f"{d:%Y/%m/%d}", 4
        for k in range(chunks):
            body = ("\n".join(json.dumps(e, ensure_ascii=False) for e in events[k::chunks]) + "\n").encode()
            futures.append(pool.submit(put, f"trips/{part}/trip_events_{d:%Y%m%d}_{k}.json", body))
        futures.append(pool.submit(put, f"fleet/{part}/vehicles.csv", csv_bytes(fleet)))
        futures.append(pool.submit(put, f"fleet/{part}/maintenance.csv", csv_bytes(maint)))
        if not truncate:  # incremental re-run of specific days: replace by id
            ids = [r[0] for r in payments]
            for j in range(0, len(ids), 1000):
                cur.execute("DELETE FROM billing.payments WHERE payment_id IN (" + ",".join(["%s"] * len(ids[j:j+1000])) + ")",
                            tuple(ids[j:j + 1000]))
            conn.commit()
        pending += payments
        if len(pending) >= 100_000 or i == args.days - 1:
            conn.bulk_copy("billing.payments", pending, column_ids=list(range(1, len(PAYMENT_COLS) + 1)), batch_size=20_000)
            conn.commit()  # without this the whole payments load silently rolls back on close
            pending = []
        for k, n in (("events", len(events)), ("payments", len(payments)), ("fleet", len(fleet)), ("maint", len(maint))):
            totals[k] += n
        if i % 30 == 0 or i == args.days - 1:
            print(f"  {d}: events={len(events):>6} payments={len(payments):>5} fleet={len(fleet)} "
                  f"| totals events={totals['events']:,} payments={totals['payments']:,}  ({time.time()-t0:.0f}s)", flush=True)
        if len(futures) > 400:  # keep memory bounded
            for f in futures:
                f.result()
            futures = []
    for f in futures:
        f.result()
    pool.shutdown()

    # Verify what actually landed in SQL (a full run must match exactly; an incremental run at least).
    cur.execute("SELECT (SELECT COUNT(*) FROM billing.payments), (SELECT COUNT(*) FROM billing.riders)")
    n_pay, n_riders = cur.fetchone()
    conn.close()
    ok = n_riders == len(gen.riders) and (n_pay == totals["payments"] if truncate else n_pay >= totals["payments"])
    print(f"SQL check: payments={n_pay:,} (generated {totals['payments']:,}), riders={n_riders:,} -> {'OK' if ok else 'MISMATCH'}")
    if not ok:
        raise SystemExit("billing tables do not match what was generated")
    print(f"done in {time.time()-t0:.0f}s: " + ", ".join(f"{k}={v:,}" for k, v in totals.items()))


if __name__ == "__main__":
    main()
