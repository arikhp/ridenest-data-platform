# PL_BACKFILL: one run moves the whole history (all dates) landing -> bronze and fully reloads Snowflake BRONZE.
# ~8 copy activities total instead of ~9 per day, which is what makes a 1-year backfill cost ~$1, not ~$50.
locals {
  reload_sql = [
    for s in split(";", join("\n", [
      for l in split("\n", file("${path.module}/../../../sql/bronze/reload_bronze_full.sql")) : l if !startswith(trimspace(l), "--")
    ])) : trimspace(s) if trimspace(s) != ""
  ]
  preserve_sink_binary  = { type = "BinarySink", storeSettings = { type = "AzureBlobFSWriteSettings", copyBehavior = "PreserveHierarchy" } }
  preserve_sink_parquet = merge(local.parquet_sink, { storeSettings = { type = "AzureBlobFSWriteSettings", copyBehavior = "PreserveHierarchy" } })

  backfill_csv = {
    Backfill_FleetVehicles    = { file = "vehicles.csv", dest = "raw/fleet_vehicles" }
    Backfill_FleetMaintenance = { file = "maintenance.csv", dest = "raw/fleet_maintenance" }
  }
  backfill_sql = {
    Backfill_BillingPayments = { query = "SELECT * FROM billing.payments", dest = "raw/billing_payments/initial_load", out = "payments.parquet" }
    Backfill_BillingRiders   = { query = "SELECT * FROM billing.riders", dest = "raw/billing_riders/initial_load", out = "riders.parquet" }
    Backfill_BillingPromos   = { query = "SELECT * FROM billing.promo_codes", dest = "raw/billing_promo_codes/initial_load", out = "promo_codes.parquet" }
  }
  backfill_ref = {
    Backfill_RefZones   = { file = "zones.csv", dest = "raw/ref_zones/initial_load", out = "zones.parquet" }
    Backfill_RefPricing = { file = "pricing.csv", dest = "raw/ref_pricing/initial_load", out = "pricing.parquet" }
  }

  backfill_activities = concat(
    [{
      name = "Backfill_TripEvents", type = "Copy"
      typeProperties = {
        source = { type = "BinarySource", storeSettings = { type = "AzureBlobFSReadSettings", recursive = true, wildcardFolderPath = "trips", wildcardFileName = "*.json" } }
        sink   = local.preserve_sink_binary
      }
      inputs  = [{ referenceName = "DS_LAKE_BINARY", type = "DatasetReference", parameters = { fileSystem = "landing", folder = "trips" } }]
      outputs = [{ referenceName = "DS_LAKE_BINARY", type = "DatasetReference", parameters = { fileSystem = "bronze", folder = "raw/trip_events" } }]
    }],
    [for name, c in local.backfill_csv : {
      name = name, type = "Copy"
      typeProperties = {
        source = merge(local.csv_source, { storeSettings = { type = "AzureBlobFSReadSettings", recursive = true, wildcardFolderPath = "fleet", wildcardFileName = "*${c.file}" } }) # needs a wildcard char, else it's a literal path
        sink   = local.preserve_sink_parquet
      }
      inputs  = [{ referenceName = "DS_LAKE_CSV", type = "DatasetReference", parameters = { fileSystem = "landing", folder = "fleet", file = "" } }]
      outputs = [{ referenceName = local.pq, type = "DatasetReference", parameters = { fileSystem = "bronze", folder = c.dest, file = "" } }]
    }],
    [{
      # The full payments export below supersedes any daily payment slices; clear them so a reload
      # never counts a payment twice. (Other sources are snapshots/events keyed by date folder.)
      name = "Clear_BronzeBillingPayments", type = "Delete"
      typeProperties = {
        dataset       = { referenceName = "DS_LAKE_BINARY", type = "DatasetReference", parameters = { fileSystem = "bronze", folder = "raw/billing_payments" } }
        storeSettings = { type = "AzureBlobFSReadSettings", recursive = true }
        enableLogging = false
      }
    }],
    [for name, c in local.backfill_sql : {
      name           = name, type = "Copy"
      dependsOn      = name == "Backfill_BillingPayments" ? [{ activity = "Clear_BronzeBillingPayments", dependencyConditions = ["Succeeded"] }] : []
      typeProperties = { source = { type = "AzureSqlSource", sqlReaderQuery = c.query }, sink = local.parquet_sink }
      inputs         = [{ referenceName = "DS_SQL_BILLING", type = "DatasetReference" }]
      outputs        = [{ referenceName = local.pq, type = "DatasetReference", parameters = { fileSystem = "bronze", folder = c.dest, file = c.out } }]
    }],
    [for name, c in local.backfill_ref : {
      name           = name, type = "Copy"
      typeProperties = { source = local.csv_source, sink = local.parquet_sink }
      inputs         = [{ referenceName = "DS_LAKE_CSV", type = "DatasetReference", parameters = { fileSystem = "landing", folder = "reference", file = c.file } }]
      outputs        = [{ referenceName = local.pq, type = "DatasetReference", parameters = { fileSystem = "bronze", folder = c.dest, file = c.out } }]
    }],
    [{
      name              = "Reload_Bronze_Snowflake", type = "Script"
      dependsOn         = [for n in concat(["Backfill_TripEvents"], keys(local.backfill_csv), keys(local.backfill_sql), keys(local.backfill_ref)) : { activity = n, dependencyConditions = ["Succeeded"] }]
      linkedServiceName = { referenceName = azurerm_data_factory_linked_custom_service.snowflake.name, type = "LinkedServiceReference" }
      typeProperties = {
        scripts                     = [for s in local.reload_sql : { type = "NonQuery", text = s }]
        scriptBlockExecutionTimeout = "02:00:00"
      }
    }]
  )
}

resource "azurerm_data_factory_pipeline" "backfill" {
  name            = "PL_BACKFILL"
  data_factory_id = var.data_factory_id
  description     = "One-off / disaster-recovery: copy ALL history landing -> bronze (initial_load for billing) and fully reload Snowflake BRONZE."
  activities_json = jsonencode(local.backfill_activities)
  depends_on      = [azurerm_data_factory_pipeline.ingest]
}
