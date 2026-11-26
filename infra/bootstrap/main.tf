locals {
  project = "ridenest"
  # Deterministic suffix keeps globally-unique names stable per subscription.
  suffix = substr(sha1(var.subscription_id), 0, 6)
  # GitHub's OIDC `sub` for repos created since 2026 embeds immutable numeric IDs
  # (repo:<owner>@<owner_id>/<repo>@<repo_id>:...), so a re-created repo with the same name can't impersonate it.
  gh_subject_prefix = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}"
  tags = {
    project    = local.project
    managed_by = "terraform"
  }
}

data "azurerm_client_config" "current" {}

# ---------- The ONE resource group for all RideNest Azure resources ----------
# Environments are separated by resource names (…-dev / …-preprod / …-prod),
# an `env` tag, and separate Terraform state files — not by resource group.
resource "azurerm_resource_group" "main" {
  name     = "rg-${local.project}-${var.location_short}"
  location = var.location
  tags     = local.tags
}

# ---------- Terraform remote state ----------
resource "azurerm_storage_account" "tfstate" {
  name                            = "st${local.project}tf${local.suffix}"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # Entra ID auth only
  tags                            = merge(local.tags, { env = "shared" })

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 14
    }
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# The human running Terraform locally needs data-plane access to state.
resource "azurerm_role_assignment" "me_tfstate" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---------- Deployment identity per environment (GitHub OIDC, no secrets) ----------
resource "azurerm_user_assigned_identity" "deploy" {
  for_each            = toset(var.environments)
  name                = "id-${local.project}-deploy-${each.key}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = merge(local.tags, { env = each.key })
}

# Owner on the single RG (needed to create role assignments for ADF / Snowflake identities).
# Trade-off of the one-RG design: isolation between envs is by naming + GitHub approvals.
resource "azurerm_role_assignment" "deploy_owner" {
  for_each             = toset(var.environments)
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Owner"
  principal_id         = azurerm_user_assigned_identity.deploy[each.key].principal_id
}

resource "azurerm_role_assignment" "deploy_tfstate" {
  for_each             = toset(var.environments)
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.deploy[each.key].principal_id
}

# GitHub Environment "dev|preprod|prod" -> matching identity.
resource "azurerm_federated_identity_credential" "gh_env" {
  for_each            = var.github_owner == "" ? toset([]) : toset(var.environments)
  name                = "github-env-${each.key}"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.deploy[each.key].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "${local.gh_subject_prefix}:environment:${each.key}"
}

# Pull requests run `terraform plan` against dev with the dev identity.
resource "azurerm_federated_identity_credential" "gh_pr" {
  count               = var.github_owner == "" ? 0 : 1
  name                = "github-pull-request"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.deploy["dev"].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "${local.gh_subject_prefix}:pull_request"
}

# ---------- Monthly cost guardrail (emails the subscription Owner role) ----------
resource "azurerm_consumption_budget_resource_group" "monthly" {
  name              = "budget-${local.project}-monthly"
  resource_group_id = azurerm_resource_group.main.id
  amount            = var.monthly_budget_usd
  time_grain        = "Monthly"

  time_period {
    start_date = "2026-11-01T00:00:00Z"
  }

  notification {
    enabled        = true
    operator       = "GreaterThan"
    threshold      = 60 # % of budget, actual spend
    threshold_type = "Actual"
    contact_roles  = ["Owner"]
  }

  notification {
    enabled        = true
    operator       = "GreaterThan"
    threshold      = 100
    threshold_type = "Actual"
    contact_roles  = ["Owner"]
  }

  notification {
    enabled        = true
    operator       = "GreaterThan"
    threshold      = 100
    threshold_type = "Forecasted"
    contact_roles  = ["Owner"]
  }
}

# Scheduled data runs (daily.yml) use a separate GitHub Environment without the approval gate
# (owner's decision, 2026-11-26): deployments of prod still need approval, nightly data processing does not.
# The environment only accepts runs from the main branch.
resource "azurerm_federated_identity_credential" "gh_ops" {
  for_each            = var.github_owner == "" ? {} : var.ops_environments
  name                = "github-env-${each.value}"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.deploy[each.key].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "${local.gh_subject_prefix}:environment:${each.value}"
}
