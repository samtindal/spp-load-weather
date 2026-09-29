-- Pick the weather stations, by rule rather than by hand.
-- -> staging.weather_stations (written with WRITE_TRUNCATE)
--
-- Oklahoma stations from NOAA's station list, ranked by how many days in the
-- study window they actually reported a mean temperature. The top N become
-- the temperature panel. Run once per study window (the backfill does it);
-- it is deliberately not scheduled, so the panel can't drift underneath the
-- analysis.
--
-- Completeness is measured against the days GSOD actually has, not calendar
-- days to date: the BigQuery public copy of GSOD stops updating from time to
-- time (as of September 2026 it ends at 2025-08-28), and a calendar
-- denominator would score every station as incomplete for NOAA's lag.
--
-- Cost: the _TABLE_SUFFIX range is a constant, so BigQuery scans only the
-- study-window year tables, and only the columns named here, once.
--
-- Vars: project, start_year, end_year, n_stations.

WITH
candidates AS (
  SELECT usaf, wban, name, lat, lon
  FROM `bigquery-public-data.noaa_gsod.stations`
  WHERE country = 'US' AND state = 'OK'
),
observed AS (
  SELECT
    stn,
    wban,
    COUNT(DISTINCT CONCAT(year, mo, da)) AS days_observed,
    MAX(CONCAT(year, mo, da)) AS last_obs
  FROM `bigquery-public-data.noaa_gsod.gsod*`
  WHERE _TABLE_SUFFIX BETWEEN '${start_year}' AND '${end_year}'
    AND temp != 9999.9  -- GSOD's missing-value sentinel
  GROUP BY stn, wban
),
windowed AS (
  -- Last date any station reported = the end of the data actually available.
  SELECT
    *,
    DATE_DIFF(PARSE_DATE('%Y%m%d', MAX(last_obs) OVER ()), DATE '${start_year}-01-01', DAY) + 1 AS days_in_window
  FROM observed
)
SELECT
  c.usaf,
  c.wban,
  c.name,
  c.lat,
  c.lon,
  o.days_observed,
  o.days_in_window,
  ROUND(o.days_observed / o.days_in_window, 4) AS completeness,
  ROW_NUMBER() OVER (ORDER BY o.days_observed DESC, c.usaf, c.wban) AS station_rank,
  CURRENT_TIMESTAMP() AS selected_at
FROM candidates AS c
JOIN windowed AS o ON o.stn = c.usaf AND o.wban = c.wban
QUALIFY station_rank <= ${n_stations}
