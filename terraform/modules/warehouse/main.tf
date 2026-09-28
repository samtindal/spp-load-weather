# Warehouse: three datasets (raw -> staging -> mart), their tables and views,
# the scheduled queries that move data between layers, and least-privilege
# IAM for the service account those queries run as.

locals {
  layers = {
    raw     = "Landing zone: EIA rows exactly as received, append-only."
    staging = "Typed, deduplicated, time-zone-resolved load and weather."
    mart    = "Analysis-ready views and BigQuery ML models."
  }

  # The sandbox forces a 60-day expiration on every table and partition.
  # Declaring it keeps Terraform's view of the datasets matching reality.
  sandbox_expiration_ms = 60 * 24 * 60 * 60 * 1000
}

# One dataset per layer so IAM can differ per layer: the ingestion job can
# write raw and nothing else; the scheduled queries read raw and write staging.
resource "google_bigquery_dataset" "layer" {
  for_each = local.layers

  dataset_id  = each.key
  location    = var.location
  description = each.value

  default_table_expiration_ms     = var.sandbox ? local.sandbox_expiration_ms : null
  default_partition_expiration_ms = var.sandbox ? local.sandbox_expiration_ms : null

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

  # Partitioned by ingest date, not by the hour the data describes: every
  # partition is recent, so the sandbox's 60-day partition expiry can't
  # silently drop history that a table-level expiry wouldn't.
  time_partitioning {
    type  = "DAY"
    field = "ingest_date"
  }
  # Raw grows every day and re-lands recent hours on each run. Requiring a
  # partition filter means no query can accidentally scan all of it.
  require_partition_filter = true
  clustering               = ["respondent", "type"]

  lifecycle {
    ignore_changes = [expiration_time] # set by the sandbox's dataset default
  }
}

# --- staging --------------------------------------------------------------------
#
# Terraform owns these tables' existence, location, and IAM. The pipeline owns
# their contents and exact column shape: each rebuild is a query written with
# WRITE_TRUNCATE, which replaces the schema along with the rows. Hence
# ignore_changes on schema, and no partitioning: a few MB per table gains
# nothing from it (every query bills a 10 MB minimum), and partitions keyed
# on historical dates would be expired on arrival in the sandbox.

resource "google_bigquery_table" "load_hourly" {
  dataset_id          = google_bigquery_dataset.layer["staging"].dataset_id
  table_id            = "load_hourly"
  description         = "Hourly SWPP demand (D) and EIA day-ahead forecast (DF), one row per hour per series."
  deletion_protection = false

  schema = jsonencode([
    { name = "interval_start_utc", type = "TIMESTAMP" },
    { name = "interval_end_utc", type = "TIMESTAMP", description = "EIA's period (hour-ending)" },
    { name = "local_date", type = "DATE", description = "America/Chicago date of the interval start" },
    { name = "local_hour", type = "INT64" },
    { name = "respondent", type = "STRING" },
    { name = "series", type = "STRING", description = "D or DF" },
    { name = "mw", type = "FLOAT64", description = "MWh over the hour = average MW" },
    { name = "ingested_at", type = "TIMESTAMP" },
  ])

  lifecycle {
    ignore_changes = [schema, expiration_time]
  }
}

resource "google_bigquery_table" "weather_stations" {
  dataset_id          = google_bigquery_dataset.layer["staging"].dataset_id
  table_id            = "weather_stations"
  description         = "NOAA GSOD stations in the temperature panel, chosen by sql/staging_weather_stations.sql."
  deletion_protection = false

  schema = jsonencode([
    { name = "usaf", type = "STRING" },
    { name = "wban", type = "STRING" },
    { name = "name", type = "STRING" },
    { name = "lat", type = "FLOAT64" },
    { name = "lon", type = "FLOAT64" },
    { name = "days_observed", type = "INT64" },
    { name = "days_in_window", type = "INT64" },
    { name = "completeness", type = "FLOAT64" },
    { name = "station_rank", type = "INT64" },
    { name = "selected_at", type = "TIMESTAMP" },
  ])

  lifecycle {
    ignore_changes = [schema, expiration_time]
  }
}

resource "google_bigquery_table" "weather_daily" {
  dataset_id          = google_bigquery_dataset.layer["staging"].dataset_id
  table_id            = "weather_daily"
  description         = "Daily temperature averaged across the station panel. GSOD is daily; this is its native grain."
  deletion_protection = false

  schema = jsonencode([
    { name = "obs_date", type = "DATE" },
    { name = "n_stations", type = "INT64" },
    { name = "tavg_f", type = "FLOAT64" },
    { name = "tmax_f", type = "FLOAT64" },
    { name = "tmin_f", type = "FLOAT64" },
    { name = "updated_at", type = "TIMESTAMP" },
  ])

  lifecycle {
    ignore_changes = [schema, expiration_time]
  }
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

  lifecycle {
    ignore_changes = [expiration_time]
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

  lifecycle {
    ignore_changes = [expiration_time]
  }

  depends_on = [google_bigquery_table.load_hourly, google_bigquery_table.weather_daily]
}
