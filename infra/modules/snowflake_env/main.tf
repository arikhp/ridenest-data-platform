locals {
  E      = upper(var.env)
  db     = "RIDENEST_${local.E}"
  layers = ["BRONZE", "SILVER", "GOLD"]
  roles  = ["LOADER", "TRANSFORMER", "READER"]
}

# ---------------- Database + medallion schemas ----------------
resource "snowflake_database" "this" {
  name                           = local.db
  comment                        = "RideNest ${var.env} — medallion layers as schemas"
  data_retention_time_in_days    = var.env == "prod" ? 7 : 1
  drop_public_schema_on_creation = true
}

resource "snowflake_schema" "layer" {
  for_each            = toset(local.layers)
  database            = snowflake_database.this.name
  name                = each.key
  with_managed_access = true
  comment             = "${each.key} layer"
}

resource "snowflake_schema" "governance" {
  database = snowflake_database.this.name
  name     = "GOVERNANCE"
  comment  = "Tags and policies for the catalog"
}

# ---------------- Cost guardrails ----------------
resource "snowflake_resource_monitor" "this" {
  name            = "RM_RIDENEST_${local.E}"
  credit_quota    = var.monthly_credit_quota
  frequency       = "MONTHLY"
  start_timestamp = "IMMEDIATELY"
  notify_triggers = [75, 90]
  suspend_trigger = 100
}

resource "snowflake_warehouse" "wh" {
  for_each            = toset(["LOAD", "TRANSFORM"])
  name                = "WH_${local.E}_${each.key}"
  warehouse_size      = var.warehouse_size
  auto_suspend        = 60
  auto_resume         = "true"
  initially_suspended = true
  resource_monitor    = snowflake_resource_monitor.this.name
  comment             = "RideNest ${var.env} ${lower(each.key)}"
}

# ---------------- RBAC: functional roles ----------------
resource "snowflake_account_role" "r" {
  for_each = toset(local.roles)
  name     = "${local.E}_${each.key}"
}

# Hierarchy: READER -> TRANSFORMER -> SYSADMIN ; LOADER -> SYSADMIN
resource "snowflake_grant_account_role" "reader_to_transformer" {
  role_name        = snowflake_account_role.r["READER"].name
  parent_role_name = snowflake_account_role.r["TRANSFORMER"].name
}
resource "snowflake_grant_account_role" "to_sysadmin" {
  for_each         = toset(["LOADER", "TRANSFORMER"])
  role_name        = snowflake_account_role.r[each.key].name
  parent_role_name = "SYSADMIN"
}

resource "snowflake_grant_privileges_to_account_role" "db_usage" {
  for_each          = toset(local.roles)
  account_role_name = snowflake_account_role.r[each.key].name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.this.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "wh_usage" {
  for_each = {
    LOADER      = "LOAD"
    TRANSFORMER = "TRANSFORM"
    READER      = "TRANSFORM"
  }
  account_role_name = snowflake_account_role.r[each.key].name
  privileges        = ["USAGE", "OPERATE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.wh[each.value].name
  }
}

# Schema-level privileges per role/layer
locals {
  schema_grants = {
    "LOADER-BRONZE"      = { role = "LOADER", schema = "BRONZE", privs = ["USAGE", "CREATE TABLE", "CREATE STAGE", "CREATE FILE FORMAT", "CREATE PIPE"] }
    "TRANSFORMER-BRONZE" = { role = "TRANSFORMER", schema = "BRONZE", privs = ["USAGE"] }
    "TRANSFORMER-SILVER" = { role = "TRANSFORMER", schema = "SILVER", privs = ["USAGE", "CREATE TABLE", "CREATE VIEW"] }
    "TRANSFORMER-GOLD"   = { role = "TRANSFORMER", schema = "GOLD", privs = ["USAGE", "CREATE TABLE", "CREATE VIEW"] }
    "READER-GOLD"        = { role = "READER", schema = "GOLD", privs = ["USAGE"] }
  }
  # Read access to future tables/views (managed-access schemas: owner grants are centralised)
  future_reads = {
    "TRANSFORMER-BRONZE-TABLES" = { role = "TRANSFORMER", schema = "BRONZE", type = "TABLES" }
    "READER-GOLD-TABLES"        = { role = "READER", schema = "GOLD", type = "TABLES" }
    "READER-GOLD-VIEWS"         = { role = "READER", schema = "GOLD", type = "VIEWS" }
  }
}

resource "snowflake_grant_privileges_to_account_role" "schema" {
  for_each          = local.schema_grants
  account_role_name = snowflake_account_role.r[each.value.role].name
  privileges        = each.value.privs
  on_schema {
    schema_name = "\"${local.db}\".\"${each.value.schema}\""
  }
  depends_on = [snowflake_schema.layer]
}

resource "snowflake_grant_privileges_to_account_role" "future_select" {
  for_each          = local.future_reads
  account_role_name = snowflake_account_role.r[each.value.role].name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = each.value.type
      in_schema          = "\"${local.db}\".\"${each.value.schema}\""
    }
  }
  depends_on = [snowflake_schema.layer]
}

# ---------------- Service users (key-pair only) ----------------
locals {
  svc = {
    loader = { role = "LOADER", wh = "LOAD" }
    dbt    = { role = "TRANSFORMER", wh = "TRANSFORM" }
  }
}

resource "snowflake_service_user" "svc" {
  for_each          = { for k, v in local.svc : k => v if contains(keys(var.service_user_public_keys), k) }
  name              = "SVC_RIDENEST_${local.E}_${upper(each.key)}"
  default_role      = snowflake_account_role.r[each.value.role].name
  default_warehouse = snowflake_warehouse.wh[each.value.wh].name
  default_namespace = local.db
  rsa_public_key    = var.service_user_public_keys[each.key]
  comment           = "RideNest ${var.env} ${each.key} service user"
}

resource "snowflake_grant_account_role" "svc" {
  for_each  = snowflake_service_user.svc
  role_name = snowflake_account_role.r[local.svc[each.key].role].name
  user_name = each.value.name
}

# ---------------- Azure storage integration + external stage ----------------
resource "snowflake_storage_integration_azure" "lake" {
  name                      = "SI_RIDENEST_${local.E}_LAKE"
  azure_tenant_id           = var.azure_tenant_id
  enabled                   = true
  storage_allowed_locations = ["azure://${var.lake_account_name}.blob.core.windows.net/bronze/"]
  comment                   = "Read-only access to the ${var.env} bronze container"
}

resource "snowflake_grant_privileges_to_account_role" "integration_usage" {
  account_role_name = snowflake_account_role.r["LOADER"].name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "INTEGRATION"
    object_name = snowflake_storage_integration_azure.lake.name
  }
}

resource "snowflake_stage_external_azure" "bronze" {
  database            = snowflake_database.this.name
  schema              = snowflake_schema.layer["BRONZE"].name
  name                = "ADLS_STAGE"
  url                 = "azure://${var.lake_account_name}.blob.core.windows.net/bronze/"
  storage_integration = snowflake_storage_integration_azure.lake.name
  comment             = "ADF-written raw files, partitioned raw/<source>/yyyy/mm/dd/"
}

resource "snowflake_grant_privileges_to_account_role" "stage_usage" {
  account_role_name = snowflake_account_role.r["LOADER"].name
  privileges        = ["USAGE"]
  on_schema_object {
    object_type = "STAGE"
    object_name = snowflake_stage_external_azure.bronze.fully_qualified_name
  }
}

# ---------------- Catalog tags ----------------
resource "snowflake_tag" "layer" {
  database               = snowflake_database.this.name
  schema                 = snowflake_schema.governance.name
  name                   = "LAYER"
  ordered_allowed_values = ["bronze", "silver", "gold"]
}

resource "snowflake_tag" "pii" {
  database               = snowflake_database.this.name
  schema                 = snowflake_schema.governance.name
  name                   = "PII"
  ordered_allowed_values = ["none", "low", "high"]
}

resource "snowflake_tag" "domain" {
  database = snowflake_database.this.name
  schema   = snowflake_schema.governance.name
  name     = "DOMAIN"
}

resource "snowflake_tag_association" "layer" {
  for_each           = toset(local.layers)
  object_type        = "SCHEMA"
  object_identifiers = [snowflake_schema.layer[each.key].fully_qualified_name]
  tag_id             = snowflake_tag.layer.fully_qualified_name
  tag_value          = lower(each.key)
}

# ---------------- dbt (TRANSFORMER) extras ----------------
# dbt applies PII / LAYER / DOMAIN tags to the objects it builds (catalog), so it needs
# USAGE on the GOVERNANCE schema and APPLY on each tag.
resource "snowflake_grant_privileges_to_account_role" "transformer_governance_usage" {
  account_role_name = snowflake_account_role.r["TRANSFORMER"].name
  privileges        = ["USAGE"]
  on_schema {
    schema_name = snowflake_schema.governance.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "transformer_apply_tags" {
  for_each = {
    LAYER  = snowflake_tag.layer.fully_qualified_name
    PII    = snowflake_tag.pii.fully_qualified_name
    DOMAIN = snowflake_tag.domain.fully_qualified_name
  }
  account_role_name = snowflake_account_role.r["TRANSFORMER"].name
  privileges        = ["APPLY"]
  on_schema_object {
    object_type = "TAG"
    object_name = each.value
  }
}

resource "snowflake_grant_privileges_to_account_role" "transformer_create_schema" {
  count             = var.transformer_can_create_schemas ? 1 : 0
  account_role_name = snowflake_account_role.r["TRANSFORMER"].name
  privileges        = ["CREATE SCHEMA"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.this.name
  }
}

# ---------------- BI access (Fabric / Power BI) ----------------
# Its own warehouse + monitor, so dashboard refreshes can never eat the pipeline's credits.
# LEGACY_SERVICE user: the Power BI Snowflake connector signs in with user + password; a key pair is
# attached as well so the password can be dropped once key-pair sign-in is used instead.
resource "snowflake_resource_monitor" "bi" {
  count           = var.bi_user == null ? 0 : 1
  name            = "RM_RIDENEST_${local.E}_BI"
  credit_quota    = var.bi_user.credit_quota
  frequency       = "MONTHLY"
  start_timestamp = "IMMEDIATELY"
  notify_triggers = [75, 90]
  suspend_trigger = 100
}

resource "snowflake_warehouse" "bi" {
  count               = var.bi_user == null ? 0 : 1
  name                = "WH_${local.E}_BI"
  warehouse_size      = "XSMALL"
  auto_suspend        = 60
  auto_resume         = "true"
  initially_suspended = true
  resource_monitor    = snowflake_resource_monitor.bi[0].name
  comment             = "RideNest ${var.env} BI / dashboards"
}

resource "snowflake_grant_privileges_to_account_role" "reader_bi_wh" {
  count             = var.bi_user == null ? 0 : 1
  account_role_name = snowflake_account_role.r["READER"].name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.bi[0].name
  }
}

resource "snowflake_legacy_service_user" "bi" {
  count             = var.bi_user == null ? 0 : 1
  name              = "SVC_RIDENEST_${local.E}_BI"
  password          = var.bi_user.password
  rsa_public_key    = var.bi_user.rsa_public_key
  default_role      = snowflake_account_role.r["READER"].name
  default_warehouse = snowflake_warehouse.bi[0].name
  default_namespace = "${local.db}.GOLD"
  comment           = "RideNest ${var.env} BI (Fabric / Power BI), read-only GOLD"
}

resource "snowflake_grant_account_role" "bi" {
  count     = var.bi_user == null ? 0 : 1
  role_name = snowflake_account_role.r["READER"].name
  user_name = snowflake_legacy_service_user.bi[0].name
}
