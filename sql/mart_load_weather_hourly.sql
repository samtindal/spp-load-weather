-- mart.load_weather_hourly (view): hourly load and EIA's day-ahead forecast,
-- side by side, with that day's temperature attached. Feeds the forecast.
--
-- The temperature is daily, repeated across the day's hours. The hourly
-- shape comes from the model's own seasonality, not the regressor; the README
-- names this limitation.
--
-- Vars: project.

SELECT
  l.interval_start_utc,
  l.local_date,
  l.local_hour,
  MAX(IF(l.series = 'D', l.mw, NULL)) AS load_mw,
  MAX(IF(l.series = 'DF', l.mw, NULL)) AS eia_forecast_mw,
  ANY_VALUE(w.tavg_f) AS tavg_f,
  ANY_VALUE(GREATEST(65 - w.tavg_f, 0)) AS hdd65,
  ANY_VALUE(GREATEST(w.tavg_f - 65, 0)) AS cdd65
FROM `${project}.staging.load_hourly` AS l
LEFT JOIN `${project}.staging.weather_daily` AS w
  ON w.obs_date = l.local_date
WHERE l.respondent = 'SWPP'
GROUP BY l.interval_start_utc, l.local_date, l.local_hour
