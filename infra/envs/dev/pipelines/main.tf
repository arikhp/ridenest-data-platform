# Data Factory linked services, datasets, pipelines and triggers for RideNest dev.
# Separate root/state: depends on both the Azure root and the Snowflake root.
terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
  backend "azurerm" {
    key = "dev-pipelines.tfstate" # rest comes from ../../backend.hcl
  }
}

provider "azurerm" {
  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true
}

variable "subscription_id" { type = string }
variable "snowflake_account" {
  type    = string
  default = "QKVPWRB-GB28666"
}
variable "schedule_enabled" {
  type    = bool
  default = false # only prod runs on a schedule; dev/preprod are triggered by CI or by hand
}

locals {
  env    = "dev"
  rg     = "rg-ridenest-ilc"
  suffix = substr(sha1(var.subscription_id), 0, 6)
}

data "azurerm_data_factory" "adf" {
  name                = "adf-ridenest-${local.env}-${local.suffix}"
  resource_group_name = local.rg
}

data "azurerm_key_vault" "kv" {
  name                = "kv-ridenest-${local.env}-${substr(local.suffix, 0, 4)}"
  resource_group_name = local.rg
}

data "azurerm_storage_account" "lake" {
  name                = "stridenest${local.env}${local.suffix}"
  resource_group_name = local.rg
}

module "pipelines" {
  source            = "../../../modules/adf_pipelines"
  env               = local.env
  data_factory_id   = data.azurerm_data_factory.adf.id
  key_vault_id      = data.azurerm_key_vault.kv.id
  lake_dfs_endpoint = data.azurerm_storage_account.lake.primary_dfs_endpoint
  snowflake_account = var.snowflake_account
  schedule_enabled  = var.schedule_enabled
}

output "pipelines" {
  value = module.pipelines
}
