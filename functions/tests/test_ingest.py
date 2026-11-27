import json
from datetime import timedelta

import pytest
from conftest import NOW, FakeApis
from ridenest_ingest import core


def test_blob_path_is_deterministic_and_hourly():
    w = core.floor_window(NOW)
    assert core.blob_path("weather", w) == "raw/api_weather/2026/11/27/10/weather_20261127T1020.json"


def test_first_scheduled_run_pulls_last_closed_window(ctx):
    summary = core.run_scheduled(ctx, now=NOW)
    assert summary["vehicle_telemetry"]["windows"] == 1
    last_closed = core.floor_window(NOW - core.SETTLE) - core.WINDOW
    path = core.blob_path("vehicle_telemetry", last_closed)
    assert path.endswith("_20261127T1010.json")
    rows = ctx.lake.rows(path)
    assert len(rows) == summary["vehicle_telemetry"]["records"] > 50  # needed more than one page (page_size=50)
    assert json.loads(ctx.state.get("vehicle_telemetry.json"))["next_window"].startswith("2026-11-27T10:20")
    weather = ctx.lake.rows(core.blob_path("weather", last_closed))
    assert {r["city"] for r in weather} == {"TLV", "BER", "LIS"} and weather[0]["mode"] == "current"


def test_catch_up_is_capped_and_resumes(ctx):
    ctx.state.put(
        "vehicle_telemetry.json", json.dumps({"next_window": (NOW - timedelta(hours=5)).isoformat()}).encode()
    )
    s = core.run_scheduled(ctx, now=NOW, sources=("vehicle_telemetry",))["vehicle_telemetry"]
    assert s["windows"] == core.MAX_CATCH_UP_WINDOWS and s["behind_windows"] > 0
    s2 = core.run_scheduled(ctx, now=NOW, sources=("vehicle_telemetry",))["vehicle_telemetry"]
    assert s2["behind_windows"] == s["behind_windows"] - s2["windows"] or s2["behind_windows"] == 0


def test_rate_limit_is_retried():
    apis = FakeApis(throttle_first=3)
    from conftest import MemoryStore

    c = core.Context(
        transport=apis,
        lake=MemoryStore(),
        state=MemoryStore(),
        mock_api_base_url="https://m",
        mock_api_key="test-key",
        sleep=lambda s: None,
    )
    core.run_scheduled(c, now=NOW, sources=("vehicle_telemetry",))
    assert sum("/v1/telemetry" in u for u in apis.calls) >= 4


def test_auth_error_is_not_retried(ctx):
    ctx.mock_api_key = "wrong"
    with pytest.raises(core.HttpError) as e:
        core.run_scheduled(ctx, now=NOW, sources=("vehicle_telemetry",))
    assert e.value.status == 401 and len(ctx.apis.calls) == 1
    assert ctx.state.get("vehicle_telemetry.json") is None  # cursor did not move


def test_backfill_is_idempotent_and_leaves_cursor(ctx):
    start = NOW.replace(hour=0, minute=0, second=0) - timedelta(days=1)
    s1 = core.run_backfill(ctx, start, start + timedelta(hours=2), now=NOW)
    snapshot = dict(ctx.lake.files)
    s2 = core.run_backfill(ctx, start, start + timedelta(hours=2), now=NOW)
    assert s1 == s2 and ctx.lake.files == snapshot
    assert s1["vehicle_telemetry"]["windows"] == 12
    assert s1["weather"]["records"] == 2 * 3  # hourly: one observation per city per full hour
    assert ctx.state.get("vehicle_telemetry.json") is None


def test_backfill_limits(ctx):
    with pytest.raises(ValueError):
        core.run_backfill(ctx, NOW - timedelta(days=9), NOW, now=NOW)
    with pytest.raises(ValueError):
        core.run_backfill(ctx, NOW - timedelta(hours=1), NOW, sources=("nope",), now=NOW)
