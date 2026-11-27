"""Pull external APIs in 10-minute windows and land one NDJSON file per source per window in bronze/raw/.

File names are a pure function of (source, window), so a re-run or backfill of a window overwrites the same
file: Snowpipe will not load a file name twice, and SILVER dedupes on the record key anyway.

Sources
  vehicle_telemetry  ScootTrack mock vendor API: API key, paging, 429s, late + duplicate readings.
                     Window semantics: readings the vendor RECEIVED in [window, window + 10 min).
  weather            Open-Meteo (real, keyless). Recent windows: `current` conditions per city.
                     Older windows (catch-up / backfill): the hourly observation of every full hour in the window.
"""

from __future__ import annotations

import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Protocol

log = logging.getLogger("ridenest_ingest")

WINDOW = timedelta(minutes=10)
SETTLE = timedelta(minutes=2)  # a window is pulled 2 min after it closes
MAX_CATCH_UP_WINDOWS = 12  # per timer run (2h); a longer gap catches up over the next runs
LIVE_WEATHER_AGE = timedelta(minutes=30)
SOURCES = ("vehicle_telemetry", "weather")

CITIES = {  # same centres as generator/ridenest_gen.py
    "TLV": (32.0853, 34.7818),
    "BER": (52.5200, 13.4050),
    "LIS": (38.7223, -9.1393),
}
WEATHER_VARS = "temperature_2m,precipitation,wind_speed_10m,weather_code"


# --------------------------------------------------------------------------- windows + paths
def floor_window(ts: datetime) -> datetime:
    ts = ts.astimezone(timezone.utc)
    return ts - timedelta(minutes=ts.minute % 10, seconds=ts.second, microseconds=ts.microsecond)


def windows(start: datetime, end: datetime) -> list[datetime]:
    """Window starts covering [start, end), aligned to 10 minutes."""
    out, w = [], floor_window(start)
    while w < end:
        out.append(w)
        w += WINDOW
    return out


def blob_path(source: str, window: datetime) -> str:
    return f"raw/api_{source}/{window:%Y/%m/%d/%H}/{source}_{window:%Y%m%dT%H%M}.json"


def iso(ts: datetime) -> str:
    return ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------- HTTP with retry
class HttpError(RuntimeError):
    def __init__(self, status: int, body: str):
        super().__init__(f"HTTP {status}: {body[:300]}")
        self.status = status


Transport = Callable[[str, dict], tuple[int, dict, bytes]]


def urllib_transport(url: str, headers: dict) -> tuple[int, dict, bytes]:
    req = urllib.request.Request(url, headers={"User-Agent": "ridenest-ingest/1.0", **headers})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), e.read()


def get_json(
    transport: Transport,
    url: str,
    params: dict,
    headers: dict | None = None,
    attempts: int = 6,
    sleep: Callable[[float], None] = time.sleep,
) -> dict | list:
    full = f"{url}?{urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})}"
    for attempt in range(1, attempts + 1):
        try:
            status, resp_headers, body = transport(full, headers or {})
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            status, resp_headers, body = 0, {}, str(exc).encode()
        if status == 200:
            return json.loads(body)
        retryable = status in (0, 429) or status >= 500
        if not retryable or attempt == attempts:
            raise HttpError(status, body.decode(errors="replace"))
        retry_after = {k.lower(): v for k, v in resp_headers.items()}.get("retry-after")
        delay = float(retry_after) if retry_after else min(30.0, 0.5 * 2 ** (attempt - 1))
        log.warning("GET %s -> %s, retry %d/%d in %.1fs", url, status or "network error", attempt, attempts - 1, delay)
        sleep(delay)
    raise AssertionError("unreachable")


# --------------------------------------------------------------------------- storage
class Store(Protocol):
    def put(self, path: str, data: bytes) -> None: ...
    def get(self, path: str) -> bytes | None: ...


@dataclass
class Context:
    transport: Transport
    lake: Store  # bronze container
    state: Store  # ingest-state container
    mock_api_base_url: str
    mock_api_key: str
    weather_base_url: str = "https://api.open-meteo.com/v1/forecast"
    weather_archive_url: str = "https://archive-api.open-meteo.com/v1/archive"
    page_size: int = 500
    sleep: Callable[[float], None] = time.sleep
    _hourly_cache: dict = field(default_factory=dict)


# --------------------------------------------------------------------------- sources
def fetch_vehicle_telemetry(ctx: Context, window: datetime, now: datetime) -> list[dict]:
    rows, token = [], None
    while True:
        body = get_json(
            ctx.transport,
            f"{ctx.mock_api_base_url.rstrip('/')}/v1/telemetry",
            {
                "updated_since": iso(window),
                "until": iso(window + WINDOW),
                "page_size": ctx.page_size,
                "page_token": token,
            },
            {"X-Api-Key": ctx.mock_api_key},
            sleep=ctx.sleep,
        )
        rows.extend(body["data"])
        token = body.get("next_page_token")
        if not token:
            return rows


def _weather_params(**extra) -> dict:
    return {
        "latitude": ",".join(str(c[0]) for c in CITIES.values()),
        "longitude": ",".join(str(c[1]) for c in CITIES.values()),
        "timezone": "UTC",
        **extra,
    }


def fetch_weather(ctx: Context, window: datetime, now: datetime) -> list[dict]:
    fetched_at = iso(now)
    if now - window <= LIVE_WEATHER_AGE:
        body = get_json(ctx.transport, ctx.weather_base_url, _weather_params(current=WEATHER_VARS), sleep=ctx.sleep)
        return [
            {
                "city": city,
                "mode": "current",
                "fetched_at": fetched_at,
                "observed_at": loc["current"]["time"] + ":00Z",
                "interval_s": loc["current"].get("interval"),
                **{k: loc["current"].get(k) for k in WEATHER_VARS.split(",")},
                "api_latitude": loc.get("latitude"),
                "api_longitude": loc.get("longitude"),
            }
            for city, loc in zip(CITIES, body, strict=True)
        ]

    # older window: the hourly observations of the full hours inside it (only the :00 window has one)
    day = window.date()
    if day not in ctx._hourly_cache:
        url = ctx.weather_archive_url if (now.date() - day).days > 60 else ctx.weather_base_url
        ctx._hourly_cache[day] = get_json(
            ctx.transport,
            url,
            _weather_params(hourly=WEATHER_VARS, start_date=day.isoformat(), end_date=day.isoformat()),
            sleep=ctx.sleep,
        )
    out = []
    for city, loc in zip(CITIES, ctx._hourly_cache[day], strict=True):
        hourly = loc["hourly"]
        for i, t in enumerate(hourly["time"]):
            ts = datetime.fromisoformat(t).replace(tzinfo=timezone.utc)
            if window <= ts < window + WINDOW:
                out.append(
                    {
                        "city": city,
                        "mode": "hourly",
                        "fetched_at": fetched_at,
                        "observed_at": t + ":00Z",
                        "interval_s": 3600,
                        **{k: hourly[k][i] for k in WEATHER_VARS.split(",")},
                        "api_latitude": loc.get("latitude"),
                        "api_longitude": loc.get("longitude"),
                    }
                )
    return out


FETCHERS = {"vehicle_telemetry": fetch_vehicle_telemetry, "weather": fetch_weather}


# --------------------------------------------------------------------------- runs
def ingest_window(ctx: Context, source: str, window: datetime, now: datetime) -> int:
    rows = FETCHERS[source](ctx, window, now)
    if rows:  # an empty window writes no file (Snowpipe would load nothing anyway)
        ctx.lake.put(
            blob_path(source, window), "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in rows).encode()
        )
    log.info("%s %s: %d records", source, iso(window), len(rows))
    return len(rows)


def run_scheduled(ctx: Context, now: datetime | None = None, sources: tuple[str, ...] = SOURCES) -> dict:
    """Timer run: every source catches up from its cursor to the last closed window. The cursor moves only
    after a window's file is written, so a failed run is simply retried by the next one."""
    now = now or datetime.now(timezone.utc)
    target_end = floor_window(now - SETTLE)
    summary = {}
    for source in sources:
        raw = ctx.state.get(f"{source}.json")
        cursor = datetime.fromisoformat(json.loads(raw)["next_window"]) if raw else target_end - WINDOW
        todo = windows(cursor, target_end)[:MAX_CATCH_UP_WINDOWS]
        counts = []
        for w in todo:
            counts.append(ingest_window(ctx, source, w, now))
            ctx.state.put(
                f"{source}.json", json.dumps({"next_window": (w + WINDOW).isoformat(), "updated_at": iso(now)}).encode()
            )
        summary[source] = {
            "windows": len(todo),
            "records": sum(counts),
            "behind_windows": len(windows(cursor, target_end)) - len(todo),
        }
    return summary


def run_backfill(
    ctx: Context,
    start: datetime,
    end: datetime,
    sources: tuple[str, ...] = SOURCES,
    now: datetime | None = None,
    max_days: int = 7,
) -> dict:
    """Re-pull [start, end) window by window. Does not touch the timer cursor."""
    now = now or datetime.now(timezone.utc)
    end = min(end, floor_window(now - SETTLE))
    if end - start > timedelta(days=max_days):
        raise ValueError(f"backfill range is limited to {max_days} days per call")
    unknown = set(sources) - set(SOURCES)
    if unknown:
        raise ValueError(f"unknown sources: {sorted(unknown)}")
    todo = windows(start, end)
    return {
        source: {"windows": len(todo), "records": sum(ingest_window(ctx, source, w, now) for w in todo)}
        for source in sources
    }


def parse_ts(value: str) -> datetime:
    ts = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)
