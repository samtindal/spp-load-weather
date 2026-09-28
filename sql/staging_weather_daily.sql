-- noaa_gsod (public) -> staging.weather_daily: one row per day, averaged
-- across the stations chosen in staging.weather_stations.
--
-- Cost: GSOD is one table per year, and a wildcard filter only prunes tables
-- when _TABLE_SUFFIX is compared to a constant. A filter computed at run time
-- (CURRENT_DATE(), a subquery) is not guaranteed to prune and can scan every
-- year since 1929. So the year range is spliced into the statement as a
-- literal with EXECUTE IMMEDIATE, and the exact dates are bound as parameters.
--
-- GSOD reports daily values, not hourly. That is the grain this table has.
--
-- Vars: project, start_date, end_date (SQL DATE expressions).

DECLARE start_date DATE DEFAULT ${start_date};
DECLARE end_date DATE DEFAULT ${end_date};

EXECUTE IMMEDIATE FORMAT("""
MERGE `${project}.staging.weather_daily` AS t
USING (
  SELECT
    DATE(CAST(g.year AS INT64), CAST(g.mo AS INT64), CAST(g.da AS INT64)) AS obs_date,
    COUNT(*) AS n_stations,
    AVG(g.temp) AS tavg_f,
    AVG(NULLIF(g.max, 9999.9)) AS tmax_f,
    AVG(NULLIF(g.min, 9999.9)) AS tmin_f
  FROM `bigquery-public-data.noaa_gsod.gsod*` AS g
  JOIN `${project}.staging.weather_stations` AS st
    ON g.stn = st.usaf AND g.wban = st.wban
  WHERE g._TABLE_SUFFIX BETWEEN '%s' AND '%s'
    AND g.temp != 9999.9
  GROUP BY obs_date
  HAVING obs_date BETWEEN @start_date AND @end_date
) AS s
ON t.obs_date = s.obs_date
WHEN MATCHED THEN
  UPDATE SET n_stations = s.n_stations, tavg_f = s.tavg_f, tmax_f = s.tmax_f, tmin_f = s.tmin_f,
             updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN
  INSERT (obs_date, n_stations, tavg_f, tmax_f, tmin_f, updated_at)
  VALUES (s.obs_date, s.n_stations, s.tavg_f, s.tmax_f, s.tmin_f, CURRENT_TIMESTAMP())
""", FORMAT_DATE('%Y', start_date), FORMAT_DATE('%Y', end_date))
USING start_date AS start_date, end_date AS end_date;
