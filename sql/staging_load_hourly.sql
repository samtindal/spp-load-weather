-- raw.eia_region_data -> staging.load_hourly
--
-- Types the value, resolves time zones, and deduplicates. Raw is an
-- append-only landing table, so the same (respondent, type, period) can
-- appear once per ingest run; the latest ingest wins, and EIA's revisions to
-- recent hours flow through as UPDATEs.
--
-- Time: EIA-930 hourly periods are UTC and hour-ENDING ("2024-07-15T20" is
-- 19:00-20:00 UTC). Local calendar fields use the interval start in
-- America/Chicago, the time zone SPP operates in, so a local day is the 24
-- (or 23/25 on DST days) hours that begin on that date.
--
-- Vars: project, since (SQL DATE expression bounding raw.ingest_date; the
-- raw table requires a partition filter, and this is it).

MERGE `${project}.staging.load_hourly` AS t
USING (
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
    WHERE ingest_date >= ${since}
      AND SAFE_CAST(value AS FLOAT64) IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY respondent, type, period ORDER BY ingested_at DESC) = 1
  )
) AS s
ON t.interval_start_utc = s.interval_start_utc
  AND t.respondent = s.respondent
  AND t.series = s.series
WHEN MATCHED AND t.mw != s.mw THEN
  UPDATE SET mw = s.mw, ingested_at = s.ingested_at
WHEN NOT MATCHED THEN
  INSERT (interval_start_utc, interval_end_utc, local_date, local_hour, respondent, series, mw, ingested_at)
  VALUES (s.interval_start_utc, s.interval_end_utc, s.local_date, s.local_hour, s.respondent, s.series, s.mw, s.ingested_at);
