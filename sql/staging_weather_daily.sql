-- noaa_gsod (public) -> staging.weather_daily (written with WRITE_TRUNCATE):
-- one row per day, averaged across the stations in staging.weather_stations.
--
-- Cost: GSOD is one table per year back to 1929, and a wildcard filter only
-- prunes tables when _TABLE_SUFFIX is compared to a constant. Both bounds
-- here are literals. The scheduled version passes end_year = '9999', which is
-- still a constant, so it picks up each new year's table as NOAA creates it
-- without ever scanning years before start_year.
--
-- GSOD reports daily values, not hourly. That is the grain this table has.
--
-- Vars: project, start_year, end_year.

SELECT
  DATE(CAST(g.year AS INT64), CAST(g.mo AS INT64), CAST(g.da AS INT64)) AS obs_date,
  COUNT(*) AS n_stations,
  AVG(g.temp) AS tavg_f,
  AVG(NULLIF(g.max, 9999.9)) AS tmax_f,
  AVG(NULLIF(g.min, 9999.9)) AS tmin_f,
  CURRENT_TIMESTAMP() AS updated_at
FROM `bigquery-public-data.noaa_gsod.gsod*` AS g
JOIN `${project}.staging.weather_stations` AS st
  ON g.stn = st.usaf AND g.wban = st.wban
WHERE g._TABLE_SUFFIX BETWEEN '${start_year}' AND '${end_year}'
  AND g.temp != 9999.9
GROUP BY obs_date
