"""ScootTrack (mock IoT vendor) telemetry: deterministic readings for the RideNest fleet.

Every vehicle that is in service reports a reading in roughly half of the 10-minute windows. Readings are a pure
function of (seed, vehicle, window), so any past window can be served again with identical content (backfills,
re-runs). Behaviour the ingestion has to cope with, like a real vendor:
  * paging (page_size, opaque page_token)
  * ~1% late readings: measured up to 40 min before the vendor received them (they show up in a later window)
  * ~0.5% duplicate deliveries (same reading_id twice)
  * the API only serves what it has received: nothing after "now"
"""

from __future__ import annotations

import base64
import hashlib
import json
import math
import random
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

WINDOW = timedelta(minutes=10)
EPOCH = datetime(2020, 1, 1, tzinfo=timezone.utc)

CITY_TZ = {"TLV": "Asia/Jerusalem", "BER": "Europe/Berlin", "LIS": "Europe/Lisbon"}
CITY_CENTER = {"TLV": (32.0853, 34.7818), "BER": (52.5200, 13.4050), "LIS": (38.7223, -9.1393)}

REPORT_RATE = 0.5  # share of windows in which a vehicle reports
LATE_RATE = 0.01
DUPLICATE_RATE = 0.005
FIRMWARE_ROLLOUT_START = date(2026, 11, 1)  # 3.5.0 rolls out to the fleet over 60 days


@dataclass(frozen=True)
class Vehicle:
    vehicle_id: str
    city: str
    lat: float
    lon: float
    vehicle_type: str
    commissioned_on: date


def load_roster(path: Path | None = None, fallback_size: int = 600) -> list[Vehicle]:
    """Fleet roster exported by generator/ridenest_gen.py --export-fleet (bundled at deploy time).
    Without it (local tests) a synthetic roster with the generator's id format is used."""
    path = path or Path(__file__).with_name("fleet_roster.json")
    if path.exists():
        rows = json.loads(path.read_text())
        return [
            Vehicle(
                r["vehicle_id"],
                r["city"],
                r["lat"],
                r["lon"],
                r["vehicle_type"],
                date.fromisoformat(r["commissioned_on"]),
            )
            for r in rows
        ]
    rng = random.Random(7)
    out = []
    for i in range(fallback_size):
        city = rng.choices(list(CITY_CENTER), [0.40, 0.35, 0.25])[0]
        lat, lon = CITY_CENTER[city]
        out.append(
            Vehicle(
                f"V{i + 1:05d}",
                city,
                lat + rng.uniform(-0.03, 0.03),
                lon + rng.uniform(-0.04, 0.04),
                rng.choice(["scooter", "scooter", "ebike"]),
                date(2025, 1, 1),
            )
        )
    return out


def floor_window(ts: datetime) -> datetime:
    ts = ts.astimezone(timezone.utc)
    return ts - timedelta(minutes=ts.minute % 10, seconds=ts.second, microseconds=ts.microsecond)


def _unit(*parts) -> float:
    """Stable pseudo-random number in [0, 1) from the parts (independent of Python's hash seed)."""
    h = hashlib.sha1("|".join(map(str, parts)).encode()).digest()
    return int.from_bytes(h[:8], "big") / 2**64


def _iso(ts: datetime) -> str:
    return ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def readings_measured_in(window_start: datetime, fleet: list[Vehicle], seed: int) -> list[dict]:
    """All readings whose measurement falls in [window_start, window_start + 10 min), with their receive time."""
    out = []
    for v in fleet:
        if v.commissioned_on > window_start.date():
            continue
        if _unit(seed, v.vehicle_id, window_start, "report") >= REPORT_RATE:
            continue
        rng = random.Random(f"{seed}|{v.vehicle_id}|{window_start.isoformat()}")
        ts = window_start + timedelta(seconds=rng.randint(0, 599))
        local_hour = ts.astimezone(ZoneInfo(CITY_TZ[v.city])).hour
        hours = (ts - EPOCH).total_seconds() / 3600

        # battery: discharge cycle of ~36h per vehicle with a fixed phase, swapped at 8-15%
        battery = round(100 - 92 * ((hours / 36 + _unit(seed, v.vehicle_id, "phase")) % 1))
        ride_p = 0.22 if 7 <= local_hour < 23 else 0.03
        r = rng.random()
        if r < 0.012:
            status = "maintenance"
        elif battery < 15:
            status = "low_battery"
        elif r < 0.012 + ride_p:
            status = "in_ride"
        else:
            status = "available"
        spread = 0.018 if status == "in_ride" else 0.007
        lat = v.lat + rng.uniform(-spread, spread)
        lon = v.lon + rng.uniform(-spread, spread) / math.cos(math.radians(v.lat))
        days_in_service = (ts.date() - v.commissioned_on).days
        odometer = 150 * _unit(seed, v.vehicle_id, "odo") + days_in_service * 6.5 + (hours % 24) * 0.27
        rollout = (ts.date() - FIRMWARE_ROLLOUT_START).days / 60
        firmware = "3.5.0" if _unit(seed, v.vehicle_id, "fw") < rollout else "3.4.1"

        received = ts + timedelta(seconds=rng.randint(2, 90))
        if rng.random() < LATE_RATE:  # device was offline, uploads later
            received = ts + timedelta(minutes=rng.randint(10, 40))
        rec = {
            "reading_id": hashlib.sha1(f"{v.vehicle_id}|{_iso(ts)}".encode()).hexdigest()[:20],
            "vehicle_id": v.vehicle_id,
            "ts": _iso(ts),
            "received_at": _iso(received),
            "lat": round(lat, 6),
            "lon": round(lon, 6),
            "battery_pct": battery,
            "status": status,
            "speed_kmh": round(rng.uniform(8, 24), 1) if status == "in_ride" else 0.0,
            "odometer_km": round(odometer, 1),
            "firmware": firmware,
        }
        out.append(rec)
        if rng.random() < DUPLICATE_RATE:
            out.append(dict(rec))
    return out


def received_between(start: datetime, end: datetime, fleet: list[Vehicle], seed: int) -> list[dict]:
    """Readings the vendor received in [start, end), sorted like the API returns them."""
    rows: list[dict] = []
    w = floor_window(start - timedelta(minutes=50))  # late readings arrive up to 40 min (+90s) after measurement
    while w < end:
        for rec in readings_measured_in(w, fleet, seed):
            received = datetime.fromisoformat(rec["received_at"].replace("Z", "+00:00"))
            if start <= received < end:
                rows.append(rec)
        w += WINDOW
    rows.sort(key=lambda r: (r["received_at"], r["vehicle_id"], r["reading_id"]))
    return rows


def encode_token(offset: int) -> str:
    return base64.urlsafe_b64encode(json.dumps({"o": offset}).encode()).decode()


def decode_token(token: str | None) -> int:
    if not token:
        return 0
    return int(json.loads(base64.urlsafe_b64decode(token.encode()))["o"])


def page(
    start: datetime,
    end: datetime,
    now: datetime,
    fleet: list[Vehicle],
    seed: int,
    page_size: int,
    page_token: str | None,
) -> dict:
    end = min(end, now)  # nothing received yet after "now"
    rows = received_between(start, end, fleet, seed) if start < end else []
    offset = decode_token(page_token)
    chunk = rows[offset : offset + page_size]
    nxt = offset + page_size
    return {
        "data": chunk,
        "count": len(chunk),
        "next_page_token": encode_token(nxt) if nxt < len(rows) else None,
        "window": {"updated_since": _iso(start), "until": _iso(end)},
    }
