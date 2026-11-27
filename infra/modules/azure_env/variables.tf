variable "env" {
  type = string
  validation {
    condition     = contains(["dev", "preprod", "prod"], var.env)
    error_message = "env must be dev, preprod or prod."
  }
}
variable "resource_group_name" { type = string }
variable "suffix" {
  type        = string
  description = "Short deterministic suffix for globally unique names."
}
variable "kv_admin_object_ids" {
  type        = list(string)
  description = "Principals allowed to write Key Vault secrets (you + the env deploy identity)."
}
variable "sql_admin_login" {
  type    = string
  default = "ridenestadmin"
}
variable "log_retention_days" {
  type    = number
  default = 30
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "sql_client_ips" {
  type        = map(string)
  default     = {}
  description = "Named public IPs allowed through the SQL firewall (e.g. your laptop, for the data generator)."
}
variable "sql_auto_pause_minutes" {
  type        = number
  default     = 15 # Azure minimum; each wake-up bills compute until this delay passes
  description = "Serverless SQL pauses after this many idle minutes."
}
variable "sql_max_size_gb" {
  type    = number
  default = 2
}

# ---------------- external API ingestion ----------------
variable "ingest_schedule_enabled" {
  type        = bool
  default     = true
  description = "Run the 10-minute API pull timer. Off in dev: data arrives there only through POST /backfill."
}
variable "mockapi_429_rate" {
  type        = number
  default     = 0.05
  description = "Share of mock vendor API calls answered with 429 (exercises the client's retry logic)."
}
variable "alert_email" {
  type        = string
  default     = ""
  description = "E-mail for Azure Monitor alerts on failed ingestion runs. Empty = no alert."
}
