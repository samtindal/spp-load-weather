# Architecture

## Data flow

| Step | Component | Grain | Notes |
|---|---|---|---|
| 1 | EIA API v2, `electricity/rto/region-data`, respondent `SWPP`, types `D` + `DF` | hourly, UTC, hour-ending | SWPP, not SPP, is the API's code for Southwest Power Pool. 5,000-row page limit. |
| 2 | `spp_load_weather` (local backfill or Cloud Run Job) | same | Pages with `offset`/`length` under a total sort order, retries 429/5xx with backoff, asserts the row count equals the API's `total`. |
| 3 | NDJSON file (local `data/` or `gs://…-eia-landing`) | same | One file per run, named by window and run time. |
| 4 | `raw.eia_region_data` | same | Load job, append. Values kept as received (strings). Partitioned by `ingest_date`. |
| 5 | `staging.load_hourly` | one row per hour per series | Rebuilt (WRITE_TRUNCATE): typed, validated (15–80 GW), latest ingest wins, UTC → America/Chicago. |
| 6 | `staging.weather_stations` | one row per station | Top-N Oklahoma stations by reporting completeness. |
| 7 | `staging.weather_daily` | one row per day | Rebuilt from `noaa_gsod.gsod*`, suffix-pruned, averaged across the panel. |
| 8 | `mart.load_weather_daily`, `mart.load_weather_hourly` | day / hour | Views. |
| 9 | `mart.load_forecast_xreg` | model | BQML `ARIMA_PLUS_XREG`, retrained per backtest origin by the notebook. |

## Identities

| Service account | Can | Cannot |
|---|---|---|
| `eia-ingest` | read the EIA key secret; write the landing bucket; run BigQuery jobs; edit `raw` | touch `staging` or `mart`; read other secrets |
| `eia-ingest-scheduler` | start the `eia-ingest` job | anything else |
| `bq-scheduled-queries` | run BigQuery jobs; read `raw`; edit `staging` | write `raw` or `mart` |
| BigQuery Data Transfer agent (Google-managed) | mint tokens for `bq-scheduled-queries` only | act as any other account |

## Schedules (Phase 2, UTC)

| Time | What |
|---|---|
| 06:00 | Cloud Scheduler → `eia-ingest` job: last 3 days from EIA into raw |
| 07:00 | Scheduled query: raw → `staging.load_hourly` (full rebuild) |
| 07:15 | Scheduled query: GSOD → `staging.weather_daily` (full rebuild, study years only) |

In sandbox mode there are no schedules: `make backfill` runs the same SQL on demand.

## Layout

```
terraform/
  bootstrap/            state bucket (local state)
  main.tf providers.tf variables.tf outputs.tf
  modules/warehouse/    datasets, tables, views, scheduled queries, IAM
  modules/ingestion/    bucket, secret, registry, Cloud Run Job, Scheduler, IAM
  modules/governance/   BigQuery quota, budget, alert channel
ingest/                 Python package spp-load-weather (import: spp_load_weather), Dockerfile, tests
sql/                    every query, rendered by both Terraform and Python
notebooks/              analysis, committed with outputs
docs/                   this file, cost.md, decisions.md
```
