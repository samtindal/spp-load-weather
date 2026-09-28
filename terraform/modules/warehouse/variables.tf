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

variable "enable_schedules" {
  type = bool
}

variable "data_transfer_agent_email" {
  type        = string
  description = "The BigQuery Data Transfer Service agent, which mints tokens for the scheduled-query service account."
}

variable "load_lookback_days" {
  type        = number
  default     = 7
  description = "Raw partitions the daily staging MERGE re-reads. Covers EIA's revisions to recent hours and a missed day or two."
}

variable "weather_lookback_days" {
  type        = number
  default     = 14
  description = "GSOD posts with a lag of a few days, so the daily weather MERGE re-reads two weeks."
}
