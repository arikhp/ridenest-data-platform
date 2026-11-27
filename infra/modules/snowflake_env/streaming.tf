# ---------------- External API sources: Snowpipe auto-ingest ----------------
# The ingest Function writes bronze/raw/api_<source>/yyyy/MM/dd/HH/<source>_<window>.json; Event Grid puts a
# BlobCreated message on the lake's `snowpipe-events` queue; each pipe loads its own folder within ~1 min.
# Snowpipe is serverless (per-second compute + a tiny per-file fee): no warehouse wakes up every 10 minutes.
# Snowpipe never loads the same file name twice, so re-running a window cannot duplicate BRONZE rows.

locals {
  api_sources = {
    vehicle_telemetry = "ScootTrack mock vendor API: vehicle readings, one NDJSON file per 10-minute window (late + duplicate readings included)."
    weather           = "Open-Meteo weather per city: current conditions every 10 min, hourly observations for backfilled windows."
  }
}

resource "snowflake_notification_integration" "lake_events" {
  name                            = "NI_RIDENEST_${local.E}_LAKE_EVENTS"
  notification_provider           = "AZURE_STORAGE_QUEUE"
  azure_storage_queue_primary_uri = var.lake_queue_url
  azure_tenant_id                 = var.azure_tenant_id
  enabled                         = true
  comment                         = "BlobCreated events for ${var.env} bronze/raw/api_* (Snowpipe auto-ingest)"
}

# Same shape as every other BRONZE table (sql/bronze/load_bronze.sql).
resource "snowflake_table" "raw_api" {
  for_each = local.api_sources
  database = snowflake_database.this.name
  schema   = snowflake_schema.layer["BRONZE"].name
  name     = "RAW_API_${upper(each.key)}"
  comment  = each.value

  column {
    name = "RECORD"
    type = "VARIANT"
  }
  column {
    name = "_SOURCE_FILE"
    type = "VARCHAR"
  }
  column {
    name = "_FILE_ROW"
    type = "NUMBER(38,0)"
  }
  column {
    name = "_FILE_LAST_MODIFIED"
    type = "TIMESTAMP_NTZ(9)"
  }
  column {
    name = "_LOADED_AT"
    type = "TIMESTAMP_LTZ(9)"
    default {
      expression = "CURRENT_TIMESTAMP()"
    }
  }
}

# Pipes are created only once Snowflake's notification app can read the queue (see var.auto_ingest_gate).
resource "terraform_data" "auto_ingest_gate" {
  count = var.auto_ingest_enabled ? 1 : 0
  input = var.auto_ingest_gate
}

resource "snowflake_pipe" "raw_api" {
  for_each    = var.auto_ingest_enabled ? local.api_sources : {}
  database    = snowflake_database.this.name
  schema      = snowflake_schema.layer["BRONZE"].name
  name        = "PIPE_API_${upper(each.key)}"
  auto_ingest = true
  integration = snowflake_notification_integration.lake_events.name
  comment     = "Auto-ingest bronze/raw/api_${each.key}/ into ${snowflake_table.raw_api[each.key].name}"
  # PATTERN: ADLS Gen2 lists folders as 0-byte objects; only load the .json files.
  copy_statement = "COPY INTO ${snowflake_table.raw_api[each.key].fully_qualified_name} (RECORD, _SOURCE_FILE, _FILE_ROW, _FILE_LAST_MODIFIED) FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_LAST_MODIFIED FROM @${snowflake_stage_external_azure.bronze.fully_qualified_name}/raw/api_${each.key}/) FILE_FORMAT = (TYPE = JSON) PATTERN = '.*[.]json'"

  depends_on = [terraform_data.auto_ingest_gate]
}

# LOADER watches the pipes (SYSTEM$PIPE_STATUS, COPY_HISTORY) and can refresh them after a backfill.
resource "snowflake_grant_privileges_to_account_role" "loader_pipes" {
  for_each          = snowflake_pipe.raw_api
  account_role_name = snowflake_account_role.r["LOADER"].name
  privileges        = ["MONITOR", "OPERATE"]
  on_schema_object {
    object_type = "PIPE"
    object_name = each.value.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "loader_api_tables" {
  for_each          = snowflake_table.raw_api
  account_role_name = snowflake_account_role.r["LOADER"].name
  privileges        = ["SELECT"]
  on_schema_object {
    object_type = "TABLE"
    object_name = each.value.fully_qualified_name
  }
}
