locals {
  p    = "ridenest"
  tags = merge(var.tags, { env = var.env })
}

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

data "azurerm_client_config" "current" {}

# ---------------- Monitoring ----------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.p}-${var.env}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

# ---------------- Data lake (ADLS Gen2) ----------------
resource "azurerm_storage_account" "lake" {
  name                            = "st${local.p}${var.env}${var.suffix}"
  resource_group_name             = data.azurerm_resource_group.rg.name
  location                        = data.azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true # ADLS Gen2
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # MI / Entra only
  tags                            = merge(local.tags, { domain = "lake" })
}

# landing = files as the source systems drop them; bronze = ADF-standardised raw copy that Snowflake reads
resource "azurerm_storage_data_lake_gen2_filesystem" "fs" {
  for_each           = toset(["landing", "bronze"])
  name               = each.key
  storage_account_id = azurerm_storage_account.lake.id
}

resource "azurerm_role_assignment" "me_lake" {
  for_each             = toset(var.kv_admin_object_ids)
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.key
}

# ---------------- Key Vault ----------------
resource "azurerm_key_vault" "this" {
  name                       = "kv-${local.p}-${var.env}-${substr(var.suffix, 0, 4)}"
  resource_group_name        = data.azurerm_resource_group.rg.name
  location                   = data.azurerm_resource_group.rg.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = local.tags
}

resource "azurerm_role_assignment" "kv_admins" {
  for_each             = toset(var.kv_admin_object_ids)
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.key
}

# ---------------- Azure SQL (billing source system) ----------------
resource "random_password" "sql" {
  length           = 24
  special          = true
  override_special = "!#%*-_=+"
}

resource "azurerm_mssql_server" "billing" {
  name                          = "sql-${local.p}-${var.env}-${var.suffix}"
  resource_group_name           = data.azurerm_resource_group.rg.name
  location                      = data.azurerm_resource_group.rg.location
  version                       = "12.0"
  administrator_login           = var.sql_admin_login
  administrator_login_password  = random_password.sql.result
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
  tags                          = local.tags
}

# Lets Azure services (ADF) reach the server. Mock setup — prod-grade would use private endpoints.
resource "azurerm_mssql_firewall_rule" "azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.billing.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_mssql_database" "billing" {
  name                        = "sqldb-billing"
  server_id                   = azurerm_mssql_server.billing.id
  sku_name                    = "GP_S_Gen5_1" # serverless
  min_capacity                = 0.5
  auto_pause_delay_in_minutes = var.sql_auto_pause_minutes
  max_size_gb                 = var.sql_max_size_gb
  storage_account_type        = "Local"
  tags                        = merge(local.tags, { domain = "billing" })
}

resource "azurerm_key_vault_secret" "sql_admin_password" {
  name         = "sql-admin-password"
  value        = random_password.sql.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.kv_admins]
}

resource "azurerm_key_vault_secret" "sql_connection" {
  name         = "sql-billing-connection-string"
  value        = "Server=tcp:${azurerm_mssql_server.billing.fully_qualified_domain_name},1433;Database=${azurerm_mssql_database.billing.name};User ID=${var.sql_admin_login};Password=${random_password.sql.result};Encrypt=true;Connection Timeout=30;"
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_role_assignment.kv_admins]
}

# ---------------- Data Factory ----------------
resource "azurerm_data_factory" "this" {
  name                = "adf-${local.p}-${var.env}-${var.suffix}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
  # Git integration is configured on DEV only, once the GitHub repo exists (step 6).
}

resource "azurerm_role_assignment" "adf_lake" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_data_factory.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "adf_kv" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_data_factory.this.identity[0].principal_id
}

resource "azurerm_monitor_diagnostic_setting" "adf" {
  name                           = "to-log-analytics"
  target_resource_id             = azurerm_data_factory.this.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated"

  enabled_log { category = "PipelineRuns" }
  enabled_log { category = "ActivityRuns" }
  enabled_log { category = "TriggerRuns" }
}

resource "azurerm_mssql_firewall_rule" "clients" {
  for_each         = var.sql_client_ips
  name             = "client-${each.key}"
  server_id        = azurerm_mssql_server.billing.id
  start_ip_address = each.value
  end_ip_address   = each.value
}
