# Account-level Snowflake settings shared by all RideNest environments.
# Auth: same SNOWFLAKE_* env vars as the env roots.
terraform {
  required_version = ">= 1.9"
  required_providers {
    snowflake = { source = "snowflakedb/snowflake", version = "~> 2.24" }
  }
  backend "azurerm" {
    key = "account-snowflake.tfstate" # rest comes from ../../envs/backend.hcl
  }
}

provider "snowflake" {
  role      = "ACCOUNTADMIN"
  warehouse = "COMPUTE_WH"
}

# COMPUTE_WH came with the trial and is used by Terraform and ad-hoc Snowsight work;
# it is not owned by Terraform, so we only attach a credit cap to it.
resource "snowflake_resource_monitor" "admin" {
  name            = "RM_ACCOUNT_ADMIN"
  credit_quota    = 5
  frequency       = "MONTHLY"
  start_timestamp = "IMMEDIATELY"
  notify_triggers = [75, 90]
  suspend_trigger = 100
}

resource "snowflake_execute" "compute_wh_monitor" {
  execute = "ALTER WAREHOUSE COMPUTE_WH SET RESOURCE_MONITOR = ${snowflake_resource_monitor.admin.name}"
  revert  = "ALTER WAREHOUSE COMPUTE_WH UNSET RESOURCE_MONITOR"
}
