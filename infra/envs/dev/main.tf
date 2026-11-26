terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
  backend "azurerm" {
    key = "dev.tfstate" # rest comes from ../backend.hcl
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
  subscription_id     = var.subscription_id
  storage_use_azuread = true
}

variable "subscription_id" { type = string }
variable "sql_max_size_gb" {
  type    = number
  default = 2
}

variable "sql_client_ips" {
  type    = map(string)
  default = {}
}

variable "admin_object_ids" {
  type        = list(string)
  default     = []
  description = "Humans who get data-plane access (Key Vault, lake)."
}

locals {
  env            = "dev"
  resource_group = "rg-ridenest-ilc"
  suffix         = substr(sha1(var.subscription_id), 0, 6)
  tags           = { project = "ridenest", managed_by = "terraform" }
}

data "azurerm_user_assigned_identity" "deploy" {
  name                = "id-ridenest-deploy-${local.env}"
  resource_group_name = local.resource_group
}

module "azure" {
  source              = "../../modules/azure_env"
  env                 = local.env
  resource_group_name = local.resource_group
  suffix              = local.suffix
  kv_admin_object_ids = concat(var.admin_object_ids, [data.azurerm_user_assigned_identity.deploy.principal_id])
  sql_client_ips      = var.sql_client_ips
  sql_max_size_gb     = var.sql_max_size_gb
  tags                = local.tags
}

output "azure" {
  value = module.azure
}
