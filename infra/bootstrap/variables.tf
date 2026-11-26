variable "subscription_id" {
  type        = string
  description = "Azure subscription that hosts RideNest."
}

variable "location" {
  type    = string
  default = "israelcentral"
}

variable "location_short" {
  type    = string
  default = "ilc"
}

variable "environments" {
  type    = list(string)
  default = ["dev", "preprod", "prod"]
}

variable "github_owner" {
  type        = string
  default     = ""
  description = "GitHub user/org that owns the repo. Leave empty until the repo exists; federated credentials are created once set."
}

variable "github_repo" {
  type    = string
  default = "ridenest-data-platform"
}

variable "monthly_budget_usd" {
  type        = number
  default     = 25
  description = "Alerts at 60% (~$15) and 100% actual, and at 100% forecasted."
}

variable "github_owner_id" {
  type        = string
  default     = ""
  description = "Numeric GitHub user/org id (gh api users/<owner> --jq .id)."
}

variable "github_repo_id" {
  type        = string
  default     = ""
  description = "Numeric GitHub repository id (gh api repos/<owner>/<repo> --jq .id)."
}
