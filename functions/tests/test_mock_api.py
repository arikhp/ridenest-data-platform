from datetime import timedelta

from conftest import FLEET, NOW
from mockapi import telemetry


def test_readings_are_deterministic():
    w = telemetry.floor_window(NOW - timedelta(hours=3))
    assert telemetry.readings_measured_in(w, FLEET, 42) == telemetry.readings_measured_in(w, FLEET, 42)
    assert telemetry.readings_measured_in(w, FLEET, 42) != telemetry.readings_measured_in(w, FLEET, 7)


def test_received_between_respects_bounds_and_has_late_and_duplicates():
    start = telemetry.floor_window(NOW - timedelta(days=1))
    rows = telemetry.received_between(start, start + timedelta(hours=6), FLEET, 42)
    assert rows and all(r["received_at"] >= telemetry._iso(start) for r in rows)
    ids = [r["reading_id"] for r in rows]
    assert len(ids) > len(set(ids)), "expected some duplicate deliveries"
    late = [
        r
        for r in rows
        if (
            telemetry.datetime.fromisoformat(r["received_at"].replace("Z", "+00:00"))
            - telemetry.datetime.fromisoformat(r["ts"].replace("Z", "+00:00"))
        )
        > timedelta(minutes=10)
    ]
    assert late, "expected some late readings"
    assert {r["status"] for r in rows} <= {"available", "in_ride", "low_battery", "maintenance"}


def test_paging_returns_every_row_once():
    start = telemetry.floor_window(NOW - timedelta(hours=2))
    end = start + timedelta(minutes=10)
    everything = telemetry.received_between(start, end, FLEET, 42)
    got, token = [], None
    while True:
        p = telemetry.page(start, end, NOW, FLEET, 42, 7, token)
        got += p["data"]
        token = p["next_page_token"]
        if not token:
            break
    assert got == everything


def test_nothing_after_now():
    p = telemetry.page(NOW - timedelta(minutes=1), NOW + timedelta(hours=1), NOW, FLEET, 42, 1000, None)
    assert all(r["received_at"] < telemetry._iso(NOW) for r in p["data"])
