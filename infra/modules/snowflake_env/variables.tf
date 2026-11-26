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
