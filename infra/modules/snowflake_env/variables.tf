variable "env" { type = string }
variable "azure_tenant_id" { type = string }
variable "lake_account_name" {
  type        = string
  description = "ADLS Gen2 account whose `bronze` container Snowflake reads."
}
variable "warehouse_size" {
  type    = string
  default = "XSMALL"
}
variable "monthly_credit_quota" {
  type    = number
  default = 5
}
variable "service_user_public_keys" {
  type        = map(string)
  default     = {}
  description = "RSA public keys (PEM body, no header/footer) for service users: keys `loader` (ADF) and `dbt`. Users are created only when a key is given."
}

variable "transformer_can_create_schemas" {
  type        = bool
  default     = false
  description = "Let <ENV>_TRANSFORMER create schemas (dev only: per-PR dbt schemas like PR_12_SILVER)."
}

variable "bi_user" {
  type = object({
    password       = string
    rsa_public_key = string
    credit_quota   = optional(number, 2)
  })
  default     = null
  sensitive   = true
  description = "Read-only BI user (Fabric / Power BI) on <ENV>_READER with its own XS warehouse and credit cap. Null = none."
}

# ---------------- external API sources (Snowpipe) ----------------
variable "lake_queue_url" {
  type        = string
  description = "https://<lake>.queue.core.windows.net/snowpipe-events - Event Grid BlobCreated queue for bronze/raw/api_*."
}

variable "auto_ingest_enabled" {
  type        = bool
  default     = false
  description = "Create the Snowpipes. Needs Snowflake's notification app to hold Storage Queue Data Contributor on the queue (CREATE PIPE checks access)."
}

variable "auto_ingest_gate" {
  type        = string
  default     = ""
  description = "Any value known only after the queue role assignment exists (e.g. a time_sleep id), so the pipes wait for it."
}
