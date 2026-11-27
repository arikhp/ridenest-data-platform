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
output "bi_user" { value = try(snowflake_legacy_service_user.bi[0].name, null) }
output "bi_warehouse" { value = try(snowflake_warehouse.bi[0].name, null) }
# DESC NOTIFICATION INTEGRATION <name> shows AZURE_CONSENT_URL / AZURE_MULTI_TENANT_APP_NAME (a different app than the storage integration's).
output "notification_integration" { value = snowflake_notification_integration.lake_events.name }
output "pipes" { value = { for k, p in snowflake_pipe.raw_api : k => p.fully_qualified_name } }
