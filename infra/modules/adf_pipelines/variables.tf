variable "env" { type = string }
variable "data_factory_id" { type = string }
variable "key_vault_id" { type = string }
variable "lake_dfs_endpoint" { type = string }
variable "snowflake_account" {
  type        = string
  description = "<org>-<account>, e.g. QKVPWRB-GB28666"
}
variable "schedule_enabled" {
  type    = bool
  default = false
}
