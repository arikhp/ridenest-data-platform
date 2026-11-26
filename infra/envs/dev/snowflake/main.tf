# Snowflake objects for RideNest dev. Separate root/state from Azure because the
# Snowflake provider connects on load.
# Auth via env vars: SNOWFLAKE_ORGANIZATION_NAME, SNOWFLAKE_ACCOUNT_NAME, SNOWFLAKE_USER,
# SNOWFLAKE_AUTHENTICATOR=SNOWFLAKE_JWT, SNOWFLAKE_PRIVATE_KEY.
# Note: the Snowflake account (QKVPWRB-GB28666) runs on AWS eu-central-2 (Zurich) and reads Azure storage cross-cloud.
terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm   = { source = "hashicorp/azurerm", version = "~> 4.0" }
    snowflake = { source = "snowflakedb/snowflake", version = "~> 2.24" }
    tls       = { source = "hashicorp/tls", version = "~> 4.0" }
  }
  backend "azurerm" {
    key = "dev-snowflake.tfstate" # rest comes from ../../backend.hcl
  }
}

provider "azurerm" {
  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true
}

provider "snowflake" {
  role      = "ACCOUNTADMIN"
  warehouse = "COMPUTE_WH" # trial default; some reads (policy references) need a warehouse
  preview_features_enabled = [
    "snowflake_storage_integration_azure_resource",
  ]
}

variable "subscription_id" { type = string }
variable "credit_quota" {
  type    = number
  default = 5
}
variable "snowflake_sp_object_id" {
  type        = string
  default     = ""
  description = "Object ID of Snowflake's service principal in Entra (exists after the consent URL is accepted)."
}

locals {
  env    = "dev"
  suffix = substr(sha1(var.subscription_id), 0, 6)
}

data "azurerm_client_config" "current" {}

data "azurerm_storage_account" "lake" {
  name                = "stridenest${local.env}${local.suffix}"
  resource_group_name = "rg-ridenest-ilc"
}

# Key pairs for the Snowflake service users. The private key lives in Terraform state (Entra-protected
# blob) and in the env Key Vault, where ADF (loader) and the dbt job read it.
resource "tls_private_key" "svc" {
  for_each  = toset(["loader", "dbt"])
  algorithm = "RSA"
  rsa_bits  = 2048
}

data "azurerm_key_vault" "env" {
  name                = "kv-ridenest-${local.env}-${substr(local.suffix, 0, 4)}"
  resource_group_name = "rg-ridenest-ilc"
}

resource "azurerm_key_vault_secret" "svc_private_key" {
  for_each     = tls_private_key.svc
  name         = "snowflake-${each.key}-private-key"
  value        = each.value.private_key_pem_pkcs8
  key_vault_id = data.azurerm_key_vault.env.id
  content_type = "application/x-pem-file"
}

module "snowflake" {
  source                         = "../../../modules/snowflake_env"
  env                            = local.env
  azure_tenant_id                = data.azurerm_client_config.current.tenant_id
  lake_account_name              = data.azurerm_storage_account.lake.name
  monthly_credit_quota           = var.credit_quota
  transformer_can_create_schemas = true # per-PR dbt schemas
  service_user_public_keys       = { for k, key in tls_private_key.svc : k => trimspace(replace(replace(key.public_key_pem, "-----BEGIN PUBLIC KEY-----", ""), "-----END PUBLIC KEY-----", "")) }
}

# Snowflake reads bronze files through its own service principal.
resource "azurerm_role_assignment" "snowflake_lake_reader" {
  count                = var.snowflake_sp_object_id == "" ? 0 : 1
  scope                = data.azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = var.snowflake_sp_object_id
}

output "snowflake" {
  value = module.snowflake
}
