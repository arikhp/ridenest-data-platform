# ---------------- External API ingestion (every 10 min) ----------------
#   func-ridenest-mockapi-<env>  "ScootTrack" mock IoT vendor API (HTTP, API key)        - stands in for an external SaaS
#   func-ridenest-ingest-<env>   timer every 10 min + POST /backfill: pulls ScootTrack + Open-Meteo weather
#                                and writes NDJSON to bronze/raw/api_<source>/yyyy/MM/dd/HH/
#   Event Grid (BlobCreated on bronze/raw/api_*) -> storage queue -> Snowflake notification integration -> Snowpipe
# Why Functions, not ADF: an ADF copy bills >= 1 min x 4 DIU per run (~$70/month/env at 144 runs/day);
# Flex Consumption at this volume stays inside the monthly free grant.

locals {
  fn_apps = {
    mockapi = "func-${local.p}-mockapi-${var.env}-${var.suffix}"
    ingest  = "func-${local.p}-ingest-${var.env}-${var.suffix}"
  }
  kv_ref_mockapi_key = "@Microsoft.KeyVault(VaultName=${azurerm_key_vault.this.name};SecretName=${azurerm_key_vault_secret.mockapi_key.name})"
}

# Host storage for both apps (deployment packages, timer leases, cursors). Function host storage must not be an
# HNS (Data Lake) account, so this is a small separate account. Entra-only, like the lake.
resource "azurerm_storage_account" "functions" {
  name                            = "strnfn${var.env}${var.suffix}"
  resource_group_name             = data.azurerm_resource_group.rg.name
  location                        = data.azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  tags                            = merge(local.tags, { domain = "ingestion" })
}

resource "azurerm_storage_container" "functions" {
  for_each              = toset(["deploy-mockapi", "deploy-ingest", "ingest-state"])
  name                  = each.key
  storage_account_id    = azurerm_storage_account.functions.id
  container_access_type = "private"
}

resource "azurerm_application_insights" "ingest" {
  name                = "appi-${local.p}-ingest-${var.env}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "other"
  tags                = local.tags
}

# Mock vendor API key: Terraform generates it; both apps read it from Key Vault (Key Vault references).
resource "random_password" "mockapi_key" {
  length  = 40
  special = false
}

resource "azurerm_key_vault_secret" "mockapi_key" {
  name         = "mockapi-key"
  value        = random_password.mockapi_key.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.kv_admins]
}

resource "azurerm_service_plan" "fn" {
  for_each            = local.fn_apps
  name                = "asp-${local.p}-${each.key}-${var.env}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "FC1" # Flex Consumption
  tags                = local.tags
}

# The two apps share everything but their settings; separate resources so ingest can read mockapi's hostname.
locals {
  fn_common_settings = {
    AzureWebJobsStorage__accountName = azurerm_storage_account.functions.name
    MOCK_API_KEY                     = local.kv_ref_mockapi_key
  }
}

resource "azurerm_function_app_flex_consumption" "mockapi" {
  name                        = local.fn_apps.mockapi
  resource_group_name         = data.azurerm_resource_group.rg.name
  location                    = data.azurerm_resource_group.rg.location
  service_plan_id             = azurerm_service_plan.fn["mockapi"].id
  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.functions.primary_blob_endpoint}${azurerm_storage_container.functions["deploy-mockapi"].name}"
  storage_authentication_type = "SystemAssignedIdentity"
  runtime_name                = "python"
  runtime_version             = "3.12"
  instance_memory_in_mb       = 2048
  maximum_instance_count      = 40 # Flex minimum
  https_only                  = true
  tags                        = merge(local.tags, { domain = "ingestion", component = "mockapi" })

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.ingest.connection_string
    minimum_tls_version                    = "1.2"
  }

  app_settings = merge(local.fn_common_settings, {
    MOCK_ENV      = var.env
    MOCK_SEED     = "42"
    MOCK_429_RATE = tostring(var.mockapi_429_rate)
  })

  lifecycle {
    # the code package is deployed by .github/workflows/functions.yml, not Terraform
    ignore_changes = [zip_deploy_file, tags["hidden-link: /app-insights-resource-id"]]
  }
}

resource "azurerm_function_app_flex_consumption" "ingest" {
  name                        = local.fn_apps.ingest
  resource_group_name         = data.azurerm_resource_group.rg.name
  location                    = data.azurerm_resource_group.rg.location
  service_plan_id             = azurerm_service_plan.fn["ingest"].id
  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.functions.primary_blob_endpoint}${azurerm_storage_container.functions["deploy-ingest"].name}"
  storage_authentication_type = "SystemAssignedIdentity"
  runtime_name                = "python"
  runtime_version             = "3.12"
  instance_memory_in_mb       = 2048
  maximum_instance_count      = 40
  https_only                  = true
  tags                        = merge(local.tags, { domain = "ingestion", component = "ingest" })

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.ingest.connection_string
    minimum_tls_version                    = "1.2"
  }

  app_settings = merge(local.fn_common_settings, {
    INGEST_ENV        = var.env
    MOCK_API_BASE_URL = "https://${azurerm_function_app_flex_consumption.mockapi.default_hostname}"
    LAKE_BLOB_URL     = azurerm_storage_account.lake.primary_blob_endpoint
    STATE_BLOB_URL    = azurerm_storage_account.functions.primary_blob_endpoint
    # dev: no schedule, data only through POST /api/backfill (api-backfill.yml)
    "AzureWebJobs.ingest_timer.Disabled" = var.ingest_schedule_enabled ? "false" : "true"
  })

  lifecycle {
    ignore_changes = [zip_deploy_file, tags["hidden-link: /app-insights-resource-id"]]
  }
}

locals {
  fn_principals = {
    mockapi = azurerm_function_app_flex_consumption.mockapi.identity[0].principal_id
    ingest  = azurerm_function_app_flex_consumption.ingest.identity[0].principal_id
  }
}

# Identity: host storage (blobs for packages/leases/cursors, queues for the host), Key Vault, and the lake (ingest only).
resource "azurerm_role_assignment" "fn_host_blob" {
  for_each             = local.fn_apps
  scope                = azurerm_storage_account.functions.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = local.fn_principals[each.key]
}

resource "azurerm_role_assignment" "fn_host_queue" {
  for_each             = local.fn_apps
  scope                = azurerm_storage_account.functions.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = local.fn_principals[each.key]
}

resource "azurerm_role_assignment" "fn_kv" {
  for_each             = local.fn_apps
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = local.fn_principals[each.key]
}

resource "azurerm_role_assignment" "ingest_lake" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.fn_principals.ingest
}

# ---------------- Snowpipe auto-ingest notifications ----------------
# The queue lives in the lake account (queues work on HNS accounts). Snowflake's notification-integration app
# reads it (Storage Queue Data Contributor, granted in envs/<env>/snowflake once its consent is accepted).
resource "azurerm_storage_queue" "snowpipe" {
  name               = "snowpipe-events"
  storage_account_id = azurerm_storage_account.lake.id
}

resource "azurerm_eventgrid_system_topic" "lake" {
  name                = "evgt-${local.p}-${var.env}-lake"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  source_resource_id  = azurerm_storage_account.lake.id
  topic_type          = "Microsoft.Storage.StorageAccounts"
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}

# Event Grid delivers with its own identity (the lake has no shared keys).
resource "azurerm_role_assignment" "eventgrid_queue_sender" {
  scope                = "${azurerm_storage_account.lake.id}/queueServices/default/queues/${azurerm_storage_queue.snowpipe.name}"
  role_definition_name = "Storage Queue Data Message Sender"
  principal_id         = azurerm_eventgrid_system_topic.lake.identity[0].principal_id
}

# Event Grid validates delivery access when the subscription is created; a fresh role assignment takes a
# minute or two to take effect, so wait for it (first apply failed with "Managed Identity Authorization Error").
resource "time_sleep" "eventgrid_queue_role" {
  create_duration = "120s"
  triggers        = { role = azurerm_role_assignment.eventgrid_queue_sender.id }
}

resource "azurerm_eventgrid_system_topic_event_subscription" "snowpipe_api" {
  name                 = "evgs-snowpipe-api"
  system_topic         = azurerm_eventgrid_system_topic.lake.name
  resource_group_name  = data.azurerm_resource_group.rg.name
  included_event_types = ["Microsoft.Storage.BlobCreated"]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/bronze/blobs/raw/api_"
    subject_ends_with   = ".json"
  }

  delivery_identity {
    type = "SystemAssigned"
  }

  storage_queue_endpoint {
    storage_account_id                    = azurerm_storage_account.lake.id
    queue_name                            = azurerm_storage_queue.snowpipe.name
    queue_message_time_to_live_in_seconds = 7 * 24 * 3600
  }

  retry_policy {
    max_delivery_attempts = 30
    event_time_to_live    = 1440
  }

  depends_on = [time_sleep.eventgrid_queue_role]
}

# ---------------- Alerting (optional e-mail) ----------------
resource "azurerm_monitor_action_group" "ingest" {
  count               = var.alert_email == "" ? 0 : 1
  name                = "ag-${local.p}-ingest-${var.env}"
  resource_group_name = data.azurerm_resource_group.rg.name
  short_name          = "rn-ingest"
  tags                = local.tags

  email_receiver {
    name          = "owner"
    email_address = var.alert_email
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "ingest_failures" {
  count                = var.alert_email == "" ? 0 : 1
  name                 = "alert-${local.p}-ingest-${var.env}-failures"
  resource_group_name  = data.azurerm_resource_group.rg.name
  location             = data.azurerm_resource_group.rg.location
  scopes               = [azurerm_application_insights.ingest.id]
  description          = "Two or more failed API ingestion runs in 30 minutes"
  severity             = 2
  evaluation_frequency = "PT15M"
  window_duration      = "PT30M"
  tags                 = local.tags

  criteria {
    query                   = <<-KQL
      requests
      | where cloud_RoleName startswith "${local.fn_apps.ingest}" and success == false
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThanOrEqual"
    threshold               = 2
  }

  action {
    action_groups = [azurerm_monitor_action_group.ingest[0].id]
  }
}
