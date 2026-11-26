output "database" { value = snowflake_database.this.name }
output "storage_integration" { value = snowflake_storage_integration_azure.lake.name }
# Open this URL once as an Entra admin to create Snowflake's service principal in your tenant.
output "azure_consent_url" {
  value = try(snowflake_storage_integration_azure.lake.describe_output[0].consent_url, null)
}
output "azure_multi_tenant_app_name" {
  value = try(snowflake_storage_integration_azure.lake.describe_output[0].multi_tenant_app_name, null)
}
output "service_users" { value = { for k, u in snowflake_service_user.svc : k => u.name } }
