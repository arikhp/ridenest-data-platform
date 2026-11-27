"""Check that Snowpipe loaded a lake file into BRONZE (used by the deploy smoke test), or report pipe health.

  --file raw/api_<source>/.../<name>.json   wait (up to --timeout s) until its rows are in BRONZE.RAW_API_<SOURCE>
  (no --file)                               print SYSTEM$PIPE_STATUS of every API pipe; exit 1 if one is unhealthy

Auth: SVC_RIDENEST_<ENV>_LOADER key pair (env SNOWFLAKE_LOADER_PRIVATE_KEY, PEM) and SNOWFLAKE_ACCOUNT.
If the env has no pipes yet (Snowflake's queue consent not done), it says so and exits 0.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

import snowflake.connector
from cryptography.hazmat.primitives import serialization

SOURCES = ("vehicle_telemetry", "weather")


def connect(env: str):
    key = serialization.load_pem_private_key(os.environ["SNOWFLAKE_LOADER_PRIVATE_KEY"].encode(), None)
    e = env.upper()
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=f"SVC_RIDENEST_{e}_LOADER",
        private_key=key,
        role=f"{e}_LOADER",
        warehouse=f"WH_{e}_LOAD",
        database=f"RIDENEST_{e}",
        schema="BRONZE",
    )


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--env", required=True, choices=["dev", "preprod", "prod"])
    p.add_argument("--file")
    p.add_argument("--timeout", type=int, default=300)
    args = p.parse_args()
    cur = connect(args.env).cursor()

    pipes = {r[1].upper() for r in cur.execute("show pipes like 'PIPE_API_%' in schema BRONZE").fetchall()}
    if not pipes:
        print("- Snowpipe: no API pipes in this env yet (queue consent pending, see README); load check skipped")
        return 0

    unhealthy = []
    for source in SOURCES:
        name = f"PIPE_API_{source.upper()}"
        if name not in pipes:
            continue
        status = json.loads(cur.execute(f"select system$pipe_status('BRONZE.{name}')").fetchone()[0])
        state = status.get("executionState")
        print(f"- {name}: {state}, pending files {status.get('pendingFileCount', 0)}")
        if state != "RUNNING" or status.get("error"):
            unhealthy.append(name)

    if args.file:
        source = next(s for s in SOURCES if f"/api_{s}/" in f"/{args.file}")
        table = f"RAW_API_{source.upper()}"
        deadline = time.time() + args.timeout
        while time.time() < deadline:
            n = cur.execute(f"select count(*) from {table} where _source_file = %s", (args.file,)).fetchone()[0]
            if n:
                print(f"- Snowpipe: {n} rows of `{args.file}` in BRONZE.{table}")
                return 0
            time.sleep(15)
        print(f"- Snowpipe: `{args.file}` NOT loaded into BRONZE.{table} after {args.timeout}s")
        return 1
    return 1 if unhealthy else 0


if __name__ == "__main__":
    sys.exit(main())
