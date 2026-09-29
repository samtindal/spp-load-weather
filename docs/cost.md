# Cost

**Target: $0.00 a month. Actual so far: $0.00.** Run in the BigQuery sandbox, there is no billing account to charge, so $0 is
guaranteed rather than targeted. The controls below keep it $0 when the project does have billing.

## Controls

| Control | Where | What it prevents |
|---|---|---|
| Daily query quota, 20,480 MiB/day | `modules/governance` | Any month's query bytes exceeding the free tier. Enforced by BigQuery: queries past the cap fail. |
| `maximum_bytes_billed` | every backfill SQL step (4 GiB), every notebook query (256 MiB) | One bad query billing more than expected. |
| `require_partition_filter` | `raw.eia_region_data` | Full scans of the only table that grows without bound. |
| Constant `_TABLE_SUFFIX` range | `sql/staging_weather_*.sql` | Scanning ~95 years of GSOD tables to read one. |
| Batch load jobs, not streaming inserts | `spp_load_weather.main` | Streaming insert charges. |
| REST result download, not the Storage Read API | notebook | Read API charges. |
| Lifecycle rules | landing bucket (30 days), Artifact Registry (newest 3 images) | Storage creep. |
| Budget: $5, alerts at 50/90/100% + forecast | `modules/governance` | Everything else going unnoticed. |

## Why the quota is 20 GiB/day

Query usage is capped per project per day, in MiB (the unit the Service Usage API reports for
`bigquery.googleapis.com/quota/query/usage`). 20 GiB × 31 days = 620 GiB, under the 1 TiB/month on-demand free
tier, with headroom for one-off work. The real workload is far smaller:

| Workload | Approx. bytes |
|---|---|
| EIA load rebuild (raw → staging) | 4.5 MiB processed, 10 MiB billed (the minimum) |
| Station selection (once) | 655 MiB |
| Weather backfill (once) | 937 MiB |
| Daily staging rebuilds (Phase 2) | load: ~10 MB; weather: same as the weather backfill, daily |
| Notebook, top to bottom (incl. 7 BQML model fits) | 356 MiB processed, 546 MiB billed |

At this data size, nearly every query bills BigQuery's 10 MB-per-table minimum. Partitioning and clustering
don't change today's bill; they're there so the bill stays flat as the raw table grows.

## Free tiers relied on

Checked against Google Cloud's published pricing on 2026-09-28. **Re-check before quoting these anywhere; free
tiers change.**

| Service | Free tier | This project |
|---|---|---|
| BigQuery queries | 1 TiB/month | capped at 620 GiB by the quota |
| BigQuery storage | 10 GiB/month | a few MB |
| BigQuery ML (`CREATE MODEL`) | _confirm on the [pricing page](https://cloud.google.com/bigquery/pricing#bqml) before publishing_ | 7 small ARIMA fits per notebook run; the quota caps the bytes regardless |
| Batch load jobs | free | daily NDJSON loads |
| Cloud Run Jobs | 180,000 vCPU-seconds/month | ~1 run/day, well under a minute each |
| Cloud Scheduler | 3 jobs per billing account | 1 job |
| Secret Manager | 6 active versions, 10,000 access operations/month | 1 version, ~30 accesses/month |
| Cloud Storage | 5 GB-months in us-central1/us-east1/us-west1 | KBs, in us-central1 |
| Artifact Registry | 0.5 GB storage | 3 images, ~100 MB each |

BigQuery Data Transfer Service scheduled queries are charged only for the query bytes they process.
