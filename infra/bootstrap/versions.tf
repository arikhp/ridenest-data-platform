terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  # Bootstrap keeps LOCAL state on purpose: it creates the remote state storage itself.
  # The local terraform.tfstate is gitignored; keep a copy somewhere safe.
}

provider "azurerm" {
  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true
}
