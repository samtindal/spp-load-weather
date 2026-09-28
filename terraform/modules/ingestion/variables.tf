variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "image" {
  type     = string
  nullable = true
}

variable "raw_dataset_id" {
  type = string
}

variable "raw_table_id" {
  type = string
}

variable "eia_api_key" {
  type      = string
  nullable  = true
  sensitive = true
  ephemeral = true
}

variable "eia_api_key_version" {
  type = string
}

variable "schedule" {
  type        = string
  default     = "0 6 * * *"
  description = "Cron, UTC. 06:00 UTC is after EIA posts the previous day's hours."
}

variable "lookback_days" {
  type        = number
  default     = 3
  description = "Days each daily run re-fetches. EIA revises recent hours; the staging MERGE absorbs the overlap."
}

variable "landing_retention_days" {
  type        = number
  default     = 30
  description = "Landing files are loaded within minutes and reproducible from the API, so they don't need to live long."
}
