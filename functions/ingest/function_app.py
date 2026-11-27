"""RideNest API ingestion (Azure Functions, Python v2 model).

  ingest_timer   every 10 min (disabled in dev via AzureWebJobs.ingest_timer.Disabled)
  POST /api/backfill {"from": iso, "to": iso, "sources": [...]}   function key; re-pulls a range (max 7 days)

Identity: the app's system-assigned managed identity (lake: Blob Data Contributor; state account: Blob Data Owner).
"""

from __future__ import annotations

import json
import logging
import os

import azure.functions as func
from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings
from ridenest_ingest import core

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)
_credential = DefaultAzureCredential()


class BlobStore:
    def __init__(self, account_url: str, container: str, content_type: str):
        self.container = BlobServiceClient(account_url, credential=_credential).get_container_client(container)
        self.content_type = content_type

    def put(self, path: str, data: bytes) -> None:
        self.container.upload_blob(
            path, data, overwrite=True, content_settings=ContentSettings(content_type=self.content_type)
        )

    def get(self, path: str) -> bytes | None:
        try:
            return self.container.download_blob(path).readall()
        except ResourceNotFoundError:
            return None


def _context() -> core.Context:
    return core.Context(
        transport=core.urllib_transport,
        lake=BlobStore(os.environ["LAKE_BLOB_URL"], "bronze", "application/x-ndjson"),
        state=BlobStore(os.environ["STATE_BLOB_URL"], "ingest-state", "application/json"),
        mock_api_base_url=os.environ["MOCK_API_BASE_URL"],
        mock_api_key=os.environ["MOCK_API_KEY"],
    )


@app.timer_trigger(schedule="0 */10 * * * *", arg_name="timer", run_on_startup=False, use_monitor=True)
def ingest_timer(timer: func.TimerRequest) -> None:
    summary = core.run_scheduled(_context())
    logging.info("ingest summary %s", json.dumps(summary))
    for source, s in summary.items():
        if s["behind_windows"]:
            logging.warning("%s is %d windows behind; catching up over the next runs", source, s["behind_windows"])


@app.route(route="backfill", methods=["POST"])
def backfill(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
        sources = tuple(body.get("sources") or core.SOURCES)
        summary = core.run_backfill(_context(), core.parse_ts(body["from"]), core.parse_ts(body["to"]), sources)
    except (ValueError, KeyError) as exc:
        return func.HttpResponse(json.dumps({"error": str(exc)}), status_code=400, mimetype="application/json")
    logging.info("backfill %s -> %s", body, json.dumps(summary))
    return func.HttpResponse(json.dumps(summary), mimetype="application/json")
