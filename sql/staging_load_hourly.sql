-- raw.eia_region_data -> staging.load_hourly (written with WRITE_TRUNCATE)
--
-- Types the value, resolves time zones, and deduplicates. Raw is an
-- append-only landing table, so the same (respondent, type, period) can
-- appear once per ingest run; the latest ingest wins, which is also how
-- EIA's revisions to recent hours flow through.
--
-- A full rebuild rather than a MERGE: raw is ~90k rows a year, so rebuilding
-- costs the same 10 MB minimum as an incremental update, and a plain SELECT
-- runs in the BigQuery sandbox, which doesn't allow DML.
--
-- Time: EIA-930 hourly periods are UTC and hour-ENDING ("2024-07-15T20" is
-- 19:00-20:00 UTC). Local calendar fields use the interval start in
-- America/Chicago, the time zone SPP operates in, so a local day is the 24
-- (or 23/25 on DST days) hours that begin on that date.
--
-- Vars: project.

SELECT
  interval_start_utc,
  TIMESTAMP_ADD(interval_start_utc, INTERVAL 1 HOUR) AS interval_end_utc,
  DATE(interval_start_utc, 'America/Chicago') AS local_date,
  EXTRACT(HOUR FROM DATETIME(interval_start_utc, 'America/Chicago')) AS local_hour,
  respondent,
  series,
  mw,
  ingested_at
FROM (
  SELECT
    TIMESTAMP_SUB(PARSE_TIMESTAMP('%Y-%m-%dT%H', period, 'UTC'), INTERVAL 1 HOUR) AS interval_start_utc,
    respondent,
    type AS series,
    SAFE_CAST(value AS FLOAT64) AS mw,
    ingested_at
  FROM `${project}.raw.eia_region_data`
  -- The raw table requires a partition filter; this one deliberately reads all of it.
  WHERE ingest_date >= DATE '1970-01-01'
    AND SAFE_CAST(value AS FLOAT64) IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY respondent, type, period ORDER BY ingested_at DESC) = 1
)
