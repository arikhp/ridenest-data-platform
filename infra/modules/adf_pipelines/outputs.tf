output "pipeline_name" { value = azurerm_data_factory_pipeline.ingest.name }
output "bronze_statements" { value = length(local.bronze_sql) }
