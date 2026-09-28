# Warehouse: three datasets (raw -> staging -> mart), their tables and views,
# the scheduled queries that move data between layers, and least-privilege
# IAM for the service account those queries run as.

locals {
  layers = {
    raw     = "Landing zone: EIA rows exactly as received, append-only."
    staging = "Typed, deduplicated, time-zone-resolved load and weather."
    mart    = "Analysis-ready views and BigQuery ML models."
  }
}

# One dataset per layer so IAM can differ per layer: the ingestion job can
# write raw and nothing else; the scheduled queries read raw and write staging.
resource "google_bigquery_dataset" "layer" {
  for_each = local.layers

  dataset_id  = each.key
  location    = var.location
  description = each.value

  # Every layer is reproducible from the sources (EIA API, NOAA public data)
  # by re-running the backfill, so `terraform destroy` removes the data too
  # and leaves nothing billable behind.
  delete_contents_on_destroy = true
}

# --- raw ----------------------------------------------------------------------

resource "google_bigquery_table" "raw_eia_region_data" {
  dataset_id          = google_bigquery_dataset.layer["raw"].dataset_id
  table_id            = "eia_region_data"
  description         = "EIA API v2 electricity/rto/region-data rows, one load per ingest run."
  deletion_protection = false

  schema = file("${path.module}/schemas/raw_eia_region_data.json")

  time_partitioning {
    type  = "DAY"
    field = "ingest_date"
  }
  # Raw grows every day and re-lands recent hours on each run. Requiring a
  # partition filter means no query can accidentally scan all of it.
  require_partition_filter = true
  clustering               = ["respondent", "type"]
}

# --- staging --------------------------------------------------------------------

resource "google_bigquery_table" "load_hourly" {
  dataset_id          = google_bigquery_dataset.layer["staging"].dataset_id
  table_id            = "load_hourly"
  description         = "Hourly SWPP demand (D) and EIA day-ahead forecast (DF), one row per hour per series."
  deletion_protection = false

  schema = jsonencode([
    { name = "interval_start_utc", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "interval_end_utc", type = "TIMESTAMP", mode = "REQUIRED", description = "EIA's period (hour-ending)" },
    { name = "local_date", type = "DATE", mode = "REQUIRED", description = "America/Chicago date of the interval start" },
    { name = "local_hour", type = "INT64", mode = "REQUIRED" },
    { name = "respondent", type = "STRING", mode = "REQUIRED" },
    { name = "series", type = "STRING", mode = "REQUIRED", description = "D or DF" },
    { name = "mw", type = "FLOAT64", mode = "REQUIRED", description = "MWh over the hour = average MW" },
    { name = "ingested_at", type = "TIMESTAMP", mode = "REQUIRED" },
  ])

  # ~17.5k rows a year per series. Monthly partitions keep partition count
  # sane at this size; clustering orders rows for the series filter.
  time_partitioning {
    type  = "MONTH"
    field = "interval_start_utc"
  }
  clustering = ["respondent", "series"]
}

resource "google_bigquery_table" "weather_stations" {
  dataset_id          = google_bigquery_dataset.layer["staging"].dataset_id
  table_id            = "weather_stations"
  description         = "NOAA GSOD stations in the temperature panel, chosen by sql/staging_weather_stations.sql."
  deletion_protection = false

  schema = jsonencode([
    { name = "usaf", type = "STRING", mode = "REQUIRED" },
    { name = "wban", type = "STRING", mode = "REQUIRED" },
    { name = "name", type = "STRING", mode = "NULLABLE" },
    { name = "lat", type = "FLOAT64", mode = "NULLABLE" },
    { name = "lon", type = "FLOAT64", mode = "NULLABLE" },
    { name = "days_observed", type = "INT64", mode = "REQUIRED" },
    { name = "days_in_window", type = "INT64", mode = "REQUIRED" },
    { name = "completeness", type = "FLOAT64", mode = "REQUIRED" },
    { name = "station_rank", type = "INT64", mode = "REQUIRED" },
    { name = "selected_at", type = "TIMESTAMP", mode = "REQUIRED" },
  ])
}

resource "google_bigquery_table" "weather_daily" {
  dataset_id          = google_bigquery_dataset.layer["staging"].dataset_id
  table_id            = "weather_daily"
  description         = "Daily temperature averaged across the station panel. GSOD is daily; this is its native grain."
  deletion_protection = false

  # ~365 rows a year. Unpartitioned on purpose: partitions this small add
  # metadata overhead and save nothing (every query bills a 10 MB minimum).
  schema = jsonencode([
    { name = "obs_date", type = "DATE", mode = "REQUIRED" },
    { name = "n_stations", type = "INT64", mode = "REQUIRED" },
    { name = "tavg_f", type = "FLOAT64", mode = "REQUIRED" },
    { name = "tmax_f", type = "FLOAT64", mode = "NULLABLE" },
    { name = "tmin_f", type = "FLOAT64", mode = "NULLABLE" },
    { name = "updated_at", type = "TIMESTAMP", mode = "REQUIRED" },
  ])
}

# --- mart (views) --------------------------------------------------------------

resource "google_bigquery_table" "load_weather_daily" {
  dataset_id          = google_bigquery_dataset.layer["mart"].dataset_id
  table_id            = "load_weather_daily"
  description         = "One row per local day: load, EIA forecast, temperature, degree days."
  deletion_protection = false

  view {
    query          = templatefile("${var.sql_dir}/mart_load_weather_daily.sql", { project = var.project_id })
    use_legacy_sql = false
  }

  depends_on = [google_bigquery_table.load_hourly, google_bigquery_table.weather_daily]
}

resource "google_bigquery_table" "load_weather_hourly" {
  dataset_id          = google_bigquery_dataset.layer["mart"].dataset_id
  table_id            = "load_weather_hourly"
  description         = "Hourly load and EIA day-ahead forecast with that day's temperature. Forecast input."
  deletion_protection = false

  view {
    query          = templatefile("${var.sql_dir}/mart_load_weather_hourly.sql", { project = var.project_id })
    use_legacy_sql = false
  }

  depends_on = [google_bigquery_table.load_hourly, google_bigquery_table.weather_daily]
}
