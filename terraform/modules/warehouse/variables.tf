variable "project_id" {
  type = string
}

variable "location" {
  type = string
}

variable "sql_dir" {
  type        = string
  description = "Path to the repo's sql/ directory. Scheduled queries and views render the same files the backfill runs."
}

variable "sandbox" {
  type        = bool
  description = "BigQuery sandbox: 60-day expiration on everything, no Data Transfer Service."
}

variable "study_start_year" {
  type = number
}

variable "enable_schedules" {
  type = bool
}

variable "data_transfer_agent_email" {
  type        = string
  nullable    = true
  description = "The BigQuery Data Transfer Service agent, which mints tokens for the scheduled-query service account. Null in sandbox mode."
}
