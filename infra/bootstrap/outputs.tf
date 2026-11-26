output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "tfstate_storage_account" {
  value = azurerm_storage_account.tfstate.name
}

# Put these in GitHub Environment variables as AZURE_CLIENT_ID.
output "deploy_identity_client_ids" {
  value = { for k, id in azurerm_user_assigned_identity.deploy : k => id.client_id }
}
