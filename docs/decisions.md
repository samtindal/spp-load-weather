# Design decisions

Short records of the choices a reviewer is most likely to question.

## 1. Cloud Run Jobs, not Cloud Functions

Ingestion is a batch that runs to completion once a day: page through the API, write a file, load it. A Cloud
Run Job is that primitive. It has no HTTP request to hold open, so there's no request timeout to design around
(the job timeout is 15 minutes; a five-year backfill finishes in well under that). It runs the same container
image as the local backfill, so there is one code path, not a function-shaped copy of it. A function would need an
HTTP handler that exists only to be called by Scheduler.

## 2. Scheduler calls the job with OAuth, not OIDC

Starting a Cloud Run Job means calling the Cloud Run Admin API (`jobs.run` on `run.googleapis.com`). Google APIs
take OAuth access tokens. OIDC tokens are for invoking a Cloud Run *service's* own URL. The scheduler's service
account has `roles/run.invoker` on this one job and nothing else.

## 3. Weather at daily grain

NOAA GSOD, the station dataset in BigQuery's public data, is daily. Rather than interpolate a fake hourly
temperature, the degree-day regression runs on daily average load, and the hourly forecast takes daily
temperature as its regressor. This is the honest grain of the data, and the README names it as a limitation.

## 4. Stations chosen by rule

`sql/staging_weather_stations.sql` ranks Oklahoma stations by the number of days they reported a mean
temperature in the study window and keeps the top five. The rule is in version control; the resulting station
list is a table the notebook prints. Hand-picked station IDs with no explanation would be unreviewable.

## 5. Raw is append-only; staging deduplicates

Each ingestion run appends what it fetched to `raw.eia_region_data`, tagged with `ingested_at`. The staging MERGE
rebuild keeps the latest copy of each (respondent, series, hour). Re-running any window is therefore safe: raw
gains duplicate rows by design, staging never does. EIA revises recent hours, so each daily run re-fetches the last 3
days and revisions flow through as updates.

A failed run can't leave a partial load: every page is fetched and the row count checked against the API's
`total` before anything is written, and the write is one BigQuery load job, which is atomic.

## 6. EIA periods are hour-ending

EIA-930 hourly data is reported in UTC, hour-ending: period `2024-07-15T20` covers 19:00–20:00 UTC. Staging stores
both the interval start and end, and derives the local (America/Chicago) date and hour from the interval
*start*, so a local day is the hours that begin on that date. Days have 23 or 25 hours at DST changes;
`mart.load_weather_daily.is_complete` compares against the actual number of hours in that local day, and the
regression uses average MW, not the daily sum, so those days compare fairly.

## 7. Staging is rebuilt, not merged

Each staging table is a plain `SELECT` that the runner writes to its table with `WRITE_TRUNCATE`: the backfill
passes `--destination`, the scheduled queries set `destination_table_name_template`. At this size a rebuild costs
the same as an incremental `MERGE` (both hit the 10 MB minimum), it's idempotent without any merge logic, and a
query written to a destination table isn't DML, so it runs in the BigQuery sandbox. A test fails the build if any
file in `sql/` contains DML.

Terraform creates the staging tables and owns their location and IAM; the rebuilds own their exact columns
(`WRITE_TRUNCATE` replaces the schema), so the tables use `ignore_changes = [schema]`.

## 8. Mart layer as views

The mart is a few megabytes. A view costs nothing to keep and is always current; a materialized view or a
scheduled table would add refresh cost and a staleness question for no benefit at this size.

## 9. One SQL file, two runners

Each file in `sql/` uses `${name}` placeholders, a syntax Terraform's `templatefile()` and Python's
`string.Template` share. Terraform renders them into views and scheduled queries; the backfill renders the same
files with the study window's years. Both renderers fail on a missing variable, and a test renders every file.

## 10. `_TABLE_SUFFIX` bounded by constants

BigQuery only guarantees wildcard-table pruning when `_TABLE_SUFFIX` is compared to a constant, so a filter
computed at run time (`CURRENT_DATE()`, a subquery) could scan every GSOD year back to 1929. Both bounds are
literals: the backfill passes its own years, and the scheduled rebuild passes the study start year and `'9999'`.
The open upper bound picks up each new year's table as NOAA creates it, while staying a constant.

## 11. The API key never enters Terraform state

The secret version uses the provider's write-only argument (`secret_data_wo`) fed from an `ephemeral` variable.
The key reaches Secret Manager but is absent from plan output and from the state file. Rotating it means bumping
`eia_api_key_version`.

## 12. Deletion is allowed

Datasets use `delete_contents_on_destroy = true` and tables have deletion protection off. Every byte in this
warehouse can be rebuilt from public sources with `make backfill`, and a portfolio project should be able to
prove that `terraform destroy` leaves nothing billable. For a warehouse holding data that can't be re-derived,
both would be the other way around.

## 13. BigQuery sandbox as the default way to run it

The analysis needs no billing account. With `sandbox = true`, Terraform provisions only the warehouse and skips
everything the sandbox can't do: budgets and quota overrides (no billing account), scheduled queries (no Data
Transfer Service), and the Phase 2 stack (Cloud Run, Scheduler, Secret Manager and Artifact Registry need
billing). Variable validations reject those combinations at plan time. State is local, through a gitignored
`backend_override.tf`, because the sandbox can't create the state bucket.

Two sandbox rules shaped the schema: no DML (decision 7), and every table and partition expires after 60 days.
Partitions are the subtle one: they expire by partition date, so a table partitioned on the hour the data
describes would lose all but the last 60 days of history on arrival. Raw is partitioned by *ingest* date, which
is always recent; staging isn't partitioned at all.

## 14. Security scanner exceptions

checkov runs in CI with six documented skips (`.checkov.yaml`). Every other finding fails the build.

| Check | Why skipped |
|---|---|
| CKV_GCP_80, 81, 84 (customer-managed keys) | Data is public; Google-managed encryption at rest applies. Cloud KMS bills monthly per key version, which breaks the $0 target for no security gain. |
| CKV_GCP_121 (table deletion protection) | Decision 12. |
| CKV_GCP_62 (bucket access logs) | Needs a log bucket and billable log volume. Both buckets enforce public access prevention and uniform access; Cloud Audit Logs cover admin activity. |
| CKV_GCP_78 (landing bucket versioning) | Landing files are transient copies of an API response, deleted after 30 days. The state bucket is versioned. |

## 15. No cloud credentials in CI

CI runs fmt, validate, tflint, checkov, ruff and pytest, none of which touch GCP, and the tests replay recorded
API responses. There is no `terraform apply` in CI and no long-lived key in repository secrets. Plan-on-PR could
be added with Workload Identity Federation.
