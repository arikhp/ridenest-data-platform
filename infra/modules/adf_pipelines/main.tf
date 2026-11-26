locals {
  E = upper(var.env)
  # Statements of sql/bronze/load_bronze.sql, comments stripped, one per Script block.
  bronze_sql = [
    for s in split(";", join("\n", [
      for l in split("\n", file("${path.module}/../../../sql/bronze/load_bronze.sql")) : l if !startswith(trimspace(l), "--")
    ])) : trimspace(s) if trimspace(s) != ""
  ]
}

# ---------------- Linked services ----------------
resource "azurerm_data_factory_linked_service_key_vault" "kv" {
  name            = "LS_KEYVAULT"
  data_factory_id = var.data_factory_id
  key_vault_id    = var.key_vault_id
}

resource "azurerm_data_factory_linked_service_data_lake_storage_gen2" "lake" {
  name                 = "LS_LAKE"
  data_factory_id      = var.data_factory_id
  url                  = var.lake_dfs_endpoint
  use_managed_identity = true
}

resource "azurerm_data_factory_linked_service_azure_sql_database" "billing" {
  name            = "LS_SQL_BILLING"
  data_factory_id = var.data_factory_id
  key_vault_connection_string {
    linked_service_name = azurerm_data_factory_linked_service_key_vault.kv.name
    secret_name         = "sql-billing-connection-string"
  }
}

# Snowflake V2 connector, key-pair auth; private key read from Key Vault at runtime.
resource "azurerm_data_factory_linked_custom_service" "snowflake" {
  name            = "LS_SNOWFLAKE"
  data_factory_id = var.data_factory_id
  type            = "SnowflakeV2"
  type_properties_json = jsonencode({
    accountIdentifier  = var.snowflake_account
    user               = "SVC_RIDENEST_${local.E}_LOADER"
    database           = "RIDENEST_${local.E}"
    warehouse          = "WH_${local.E}_LOAD"
    role               = "${local.E}_LOADER"
    authenticationType = "KeyPair"
    privateKey = {
      type       = "AzureKeyVaultSecret"
      store      = { referenceName = azurerm_data_factory_linked_service_key_vault.kv.name, type = "LinkedServiceReference" }
      secretName = "snowflake-loader-private-key"
    }
  })
}

# ---------------- Datasets (parameterised, reused by every copy) ----------------
locals {
  lake_location = {
    type       = "AzureBlobFSLocation"
    fileSystem = { value = "@dataset().fileSystem", type = "Expression" }
    folderPath = { value = "@dataset().folder", type = "Expression" }
  }
  lake_file_location = merge(local.lake_location, { fileName = { value = "@dataset().file", type = "Expression" } })
}

resource "azurerm_data_factory_custom_dataset" "binary" {
  name            = "DS_LAKE_BINARY"
  data_factory_id = var.data_factory_id
  type            = "Binary"
  linked_service { name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name }
  parameters           = { fileSystem = "", folder = "" }
  type_properties_json = jsonencode({ location = local.lake_location })
}

resource "azurerm_data_factory_custom_dataset" "csv" {
  name            = "DS_LAKE_CSV"
  data_factory_id = var.data_factory_id
  type            = "DelimitedText"
  linked_service { name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name }
  parameters = { fileSystem = "", folder = "", file = "" }
  type_properties_json = jsonencode({
    location = local.lake_file_location, columnDelimiter = ",", escapeChar = "\\", quoteChar = "\"", firstRowAsHeader = true
  })
}

resource "azurerm_data_factory_custom_dataset" "parquet" {
  name            = "DS_LAKE_PARQUET"
  data_factory_id = var.data_factory_id
  type            = "Parquet"
  linked_service { name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name }
  parameters           = { fileSystem = "", folder = "", file = "" }
  type_properties_json = jsonencode({ location = local.lake_file_location, compressionCodec = "snappy" })
}

resource "azurerm_data_factory_custom_dataset" "sql" {
  name            = "DS_SQL_BILLING"
  data_factory_id = var.data_factory_id
  type            = "AzureSqlTable"
  linked_service { name = azurerm_data_factory_linked_service_azure_sql_database.billing.name }
  type_properties_json = jsonencode({})
}

# ---------------- Pipeline: PL_INGEST_DAILY ----------------
locals {
  after_vars = [{ activity = "Set_DatePath", dependencyConditions = ["Succeeded"] }]
  date_path  = "@variables('datePath')"
  bronze_dir = { for k in ["trip_events", "fleet_vehicles", "fleet_maintenance", "billing_riders", "billing_payments", "billing_promo_codes", "ref_zones", "ref_pricing"] :
  k => { value = "@concat('raw/${k}/', variables('datePath'))", type = "Expression" } }
  parquet_sink = { type = "ParquetSink", storeSettings = { type = "AzureBlobFSWriteSettings" }, formatSettings = { type = "ParquetWriteSettings" } }
  csv_source   = { type = "DelimitedTextSource", storeSettings = { type = "AzureBlobFSReadSettings", recursive = false }, formatSettings = { type = "DelimitedTextReadSettings", compressionProperties = null } } # ADF echoes the null back; omitting it = perpetual diff
  pq           = "DS_LAKE_PARQUET"

  # landing CSV -> bronze Parquet
  csv_copies = {
    Copy_FleetVehicles    = { folder = "@concat('fleet/', variables('datePath'))", file = "vehicles.csv", dest = "fleet_vehicles", out = "vehicles.parquet" }
    Copy_FleetMaintenance = { folder = "@concat('fleet/', variables('datePath'))", file = "maintenance.csv", dest = "fleet_maintenance", out = "maintenance.parquet" }
    Copy_RefZones         = { folder = "reference", file = "zones.csv", dest = "ref_zones", out = "zones.parquet" }
    Copy_RefPricing       = { folder = "reference", file = "pricing.csv", dest = "ref_pricing", out = "pricing.parquet" }
  }
  # billing SQL -> bronze Parquet (riders/promos full snapshot, payments = that day's slice)
  sql_copies = {
    Copy_BillingRiders = { query = "SELECT * FROM billing.riders", dest = "billing_riders", out = "riders.parquet" }
    Copy_BillingPromos = { query = "SELECT * FROM billing.promo_codes", dest = "billing_promo_codes", out = "promo_codes.parquet" }
    Copy_BillingPayments = {
      query = "@concat('SELECT * FROM billing.payments WHERE paid_at >= ''', variables('runDate'), ''' AND paid_at < DATEADD(day, 1, ''', variables('runDate'), ''')')"
      dest  = "billing_payments", out = "payments.parquet"
    }
  }

  activities = concat(
    [
      {
        name = "Set_RunDate", type = "SetVariable"
        typeProperties = { variableName = "runDate", value = {
          type  = "Expression"
          value = "@formatDateTime(if(empty(pipeline().parameters.runDate), addDays(utcNow(), -1), pipeline().parameters.runDate), 'yyyy-MM-dd')"
        } }
      },
      {
        name           = "Set_DatePath", type = "SetVariable", dependsOn = [{ activity = "Set_RunDate", dependencyConditions = ["Succeeded"] }]
        typeProperties = { variableName = "datePath", value = { type = "Expression", value = "@replace(variables('runDate'), '-', '/')" } }
      },
      {
        name = "Copy_TripEvents", type = "Copy", dependsOn = local.after_vars
        typeProperties = {
          source = { type = "BinarySource", storeSettings = {
            type               = "AzureBlobFSReadSettings", recursive = true, wildcardFileName = "*.json"
            wildcardFolderPath = { value = "@concat('trips/', variables('datePath'))", type = "Expression" }
          } }
          sink = { type = "BinarySink", storeSettings = { type = "AzureBlobFSWriteSettings" } }
        }
        inputs  = [{ referenceName = "DS_LAKE_BINARY", type = "DatasetReference", parameters = { fileSystem = "landing", folder = "trips" } }]
        outputs = [{ referenceName = "DS_LAKE_BINARY", type = "DatasetReference", parameters = { fileSystem = "bronze", folder = local.bronze_dir["trip_events"] } }]
      },
    ],
    [for name, c in local.csv_copies : {
      name           = name, type = "Copy", dependsOn = local.after_vars
      typeProperties = { source = local.csv_source, sink = local.parquet_sink }
      inputs = [{ referenceName = "DS_LAKE_CSV", type = "DatasetReference", parameters = {
        fileSystem = "landing", file = c.file
        folder     = { value = c.folder, type = "Expression" } # no leading @ = literal
      } }]
      outputs = [{ referenceName = local.pq, type = "DatasetReference", parameters = { fileSystem = "bronze", folder = local.bronze_dir[c.dest], file = c.out } }]
    }],
    [for name, c in local.sql_copies : {
      name = name, type = "Copy", dependsOn = local.after_vars
      typeProperties = {
        source = { type = "AzureSqlSource", sqlReaderQuery = { value = c.query, type = "Expression" } }
        sink   = local.parquet_sink
      }
      inputs  = [{ referenceName = "DS_SQL_BILLING", type = "DatasetReference" }]
      outputs = [{ referenceName = local.pq, type = "DatasetReference", parameters = { fileSystem = "bronze", folder = local.bronze_dir[c.dest], file = c.out } }]
    }],
    [{
      name              = "Load_Bronze_Snowflake", type = "Script"
      dependsOn         = [for n in concat(["Copy_TripEvents"], keys(local.csv_copies), keys(local.sql_copies)) : { activity = n, dependencyConditions = ["Succeeded"] }]
      linkedServiceName = { referenceName = azurerm_data_factory_linked_custom_service.snowflake.name, type = "LinkedServiceReference" }
      typeProperties = {
        # Expression + @{...} string interpolation injects the run's date path into each statement.
        scripts = [for s in local.bronze_sql : {
          type = "NonQuery"
          text = { type = "Expression", value = replace(s, "{{DATE_PATH}}", "@{variables('datePath')}") }
        }]
        scriptBlockExecutionTimeout = "02:00:00"
      }
    }]
  )
}

resource "azurerm_data_factory_pipeline" "ingest" {
  name            = "PL_INGEST_DAILY"
  data_factory_id = var.data_factory_id
  description     = "Landing + billing SQL -> ADLS bronze/raw/<source>/yyyy/MM/dd -> Snowflake BRONZE (COPY INTO). runDate empty = yesterday (UTC)."
  parameters      = { runDate = "" }
  variables       = { runDate = "", datePath = "" }
  activities_json = jsonencode(local.activities)

  depends_on = [
    azurerm_data_factory_custom_dataset.binary, azurerm_data_factory_custom_dataset.csv,
    azurerm_data_factory_custom_dataset.parquet, azurerm_data_factory_custom_dataset.sql,
  ]
}

resource "azurerm_data_factory_trigger_schedule" "daily" {
  name            = "TR_DAILY_0200_UTC"
  data_factory_id = var.data_factory_id
  pipeline_name   = azurerm_data_factory_pipeline.ingest.name
  frequency       = "Day"
  interval        = 1
  start_time      = "2026-11-26T02:00:00Z"
  activated       = var.schedule_enabled
}
