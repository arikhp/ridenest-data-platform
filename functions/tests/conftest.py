"""In-memory wiring: the ingest client talks to the real mock-API paging code and a canned Open-Meteo."""

from __future__ import annotations

import json
import urllib.parse
from datetime import datetime, timedelta, timezone

import pytest
from mockapi import telemetry
from ridenest_ingest import core

FLEET = telemetry.load_roster(fallback_size=120)
NOW = datetime(2026, 11, 27, 10, 23, 5, tzinfo=timezone.utc)


class MemoryStore:
    def __init__(self):
        self.files: dict[str, bytes] = {}

    def put(self, path, data):
        self.files[path] = data

    def get(self, path):
        return self.files.get(path)

    def rows(self, path):
        return [json.loads(line) for line in self.files[path].decode().splitlines()]


class FakeApis:
    """Transport: /v1/telemetry -> mockapi.telemetry.page; open-meteo -> canned payloads. Can inject 429s."""

    def __init__(self, now=NOW, throttle_first=0):
        self.now, self.throttle_left, self.calls = now, throttle_first, []

    def __call__(self, url, headers):
        self.calls.append(url)
        parsed = urllib.parse.urlparse(url)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(parsed.query).items()}
        if parsed.path.endswith("/v1/telemetry"):
            if headers.get("X-Api-Key") != "test-key":
                return 401, {}, b'{"error":"unauthorized"}'
            if self.throttle_left:
                self.throttle_left -= 1
                return 429, {"Retry-After": "0"}, b'{"error":"rate_limited"}'
            start = core.parse_ts(q["updated_since"])
            end = core.parse_ts(q["until"])
            body = telemetry.page(start, end, self.now, FLEET, 42, int(q["page_size"]), q.get("page_token"))
            return 200, {}, json.dumps(body).encode()
        if "current" in q:
            t = core.floor_window(self.now).strftime("%Y-%m-%dT%H:%M")
            return (
                200,
                {},
                json.dumps(
                    [
                        {
                            "latitude": 1,
                            "longitude": 2,
                            "current": {
                                "time": t,
                                "interval": 900,
                                "temperature_2m": 20.5,
                                "precipitation": 0.0,
                                "wind_speed_10m": 9.0,
                                "weather_code": 1,
                            },
                        }
                        for _ in core.CITIES
                    ]
                ).encode(),
            )
        if "hourly" in q:
            day = datetime.fromisoformat(q["start_date"])
            times = [(day + timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M") for h in range(24)]
            hourly = {"time": times, **{k: [float(h) for h in range(24)] for k in core.WEATHER_VARS.split(",")}}
            return (
                200,
                {},
                json.dumps([{"latitude": 1, "longitude": 2, "hourly": hourly} for _ in core.CITIES]).encode(),
            )
        return 404, {}, b"not found"


@pytest.fixture
def ctx():
    apis = FakeApis()
    c = core.Context(
        transport=apis,
        lake=MemoryStore(),
        state=MemoryStore(),
        mock_api_base_url="https://mock.example",
        mock_api_key="test-key",
        page_size=50,
        sleep=lambda s: None,
    )
    c.apis = apis
    return c
