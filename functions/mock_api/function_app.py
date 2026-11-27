"""ScootTrack mock vendor API (Azure Functions, Python v2 model).

  GET /v1/health                                       no auth
  GET /v1/telemetry?updated_since=&until=&page_size=&page_token=
                                                       header X-Api-Key; readings RECEIVED in [updated_since, until)
Random 429s (MOCK_429_RATE) make the client prove its retry logic.
"""

from __future__ import annotations

import hmac
import json
import os
import random
from datetime import datetime, timedelta, timezone

import azure.functions as func
from mockapi import telemetry

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

FLEET = telemetry.load_roster()
SEED = int(os.environ.get("MOCK_SEED", "42"))
MAX_RANGE = timedelta(hours=6)


def _json(body: dict, status: int = 200, headers: dict | None = None) -> func.HttpResponse:
    return func.HttpResponse(json.dumps(body), status_code=status, mimetype="application/json", headers=headers)


def _parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    ts = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)


@app.route(route="v1/health", methods=["GET"])
def health(req: func.HttpRequest) -> func.HttpResponse:
    return _json(
        {
            "status": "ok",
            "vendor": "ScootTrack (mock)",
            "fleet_size": len(FLEET),
            "env": os.environ.get("MOCK_ENV", "local"),
        }
    )


@app.route(route="v1/telemetry", methods=["GET"])
def get_telemetry(req: func.HttpRequest) -> func.HttpResponse:
    expected = os.environ.get("MOCK_API_KEY", "")
    if not expected or not hmac.compare_digest(req.headers.get("X-Api-Key", ""), expected):
        return _json({"error": "unauthorized"}, 401)
    if random.random() < float(os.environ.get("MOCK_429_RATE", "0.05")):
        return _json({"error": "rate_limited"}, 429, {"Retry-After": "1"})
    try:
        start = _parse_ts(req.params.get("updated_since"))
        now = datetime.now(timezone.utc)
        end = _parse_ts(req.params.get("until")) or now
        page_size = min(1000, max(1, int(req.params.get("page_size", "500"))))
        if start is None or end <= start or end - start > MAX_RANGE:
            raise ValueError("updated_since is required, until > updated_since, range <= 6h")
        body = telemetry.page(start, end, now, FLEET, SEED, page_size, req.params.get("page_token"))
    except (ValueError, KeyError) as exc:
        return _json({"error": "bad_request", "detail": str(exc)}, 400)
    return _json(body)
