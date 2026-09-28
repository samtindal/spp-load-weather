-- mart.load_weather_daily (view): one row per local day, analysis-ready.
--
-- A view rather than a table or materialized view: it costs nothing to keep,
-- and at a few MB, recomputing it on read is cheaper than any refresh job.
--
-- avg_load_mw (not the daily MWh sum) is the regression target, so the 23-
-- and 25-hour DST days are comparable with every other day. is_complete marks
-- days with every expected hour present; the notebook filters on it.
--
-- Degree days use the 65 F convention here for reference only. The notebook
-- estimates the actual balance point instead of assuming 65.
--
-- Vars: project.

WITH daily_load AS (
  SELECT
    local_date,
    AVG(IF(series = 'D', mw, NULL)) AS avg_load_mw,
    MAX(IF(series = 'D', mw, NULL)) AS peak_load_mw,
    AVG(IF(series = 'DF', mw, NULL)) AS avg_eia_forecast_mw,
    COUNTIF(series = 'D') AS n_hours,
    TIMESTAMP_DIFF(
      TIMESTAMP(DATE_ADD(local_date, INTERVAL 1 DAY), 'America/Chicago'),
      TIMESTAMP(local_date, 'America/Chicago'),
      HOUR
    ) AS expected_hours
  FROM `${project}.staging.load_hourly`
  WHERE respondent = 'SWPP'
  GROUP BY local_date
)
SELECT
  l.local_date AS date,
  EXTRACT(YEAR FROM l.local_date) AS year,
  EXTRACT(MONTH FROM l.local_date) AS month,
  EXTRACT(DAYOFWEEK FROM l.local_date) AS day_of_week,
  EXTRACT(DAYOFWEEK FROM l.local_date) IN (1, 7) AS is_weekend,
  l.avg_load_mw,
  l.peak_load_mw,
  l.avg_eia_forecast_mw,
  l.n_hours,
  l.n_hours = l.expected_hours AS is_complete,
  w.tavg_f,
  w.tmax_f,
  w.tmin_f,
  w.n_stations,
  GREATEST(65 - w.tavg_f, 0) AS hdd65,
  GREATEST(w.tavg_f - 65, 0) AS cdd65
FROM daily_load AS l
JOIN `${project}.staging.weather_daily` AS w
  ON w.obs_date = l.local_date
