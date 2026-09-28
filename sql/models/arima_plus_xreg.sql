-- Hourly load forecast with temperature as an external regressor.
--
-- The notebook calls this once per backtest origin (train on everything
-- before the origin, forecast the next 24 hours) and compares the result
-- with a seasonal-naive baseline and with EIA's published day-ahead forecast.
--
-- The training window is bounded (default: one year before the origin).
-- ARIMA fitting time grows with series length, and a year covers every
-- season, which is what the temperature coefficients need.
--
-- Vars: project, model_name, train_start, train_end (SQL TIMESTAMP expressions).

CREATE OR REPLACE MODEL `${project}.mart.${model_name}`
OPTIONS (
  model_type = 'ARIMA_PLUS_XREG',
  time_series_timestamp_col = 'interval_start_utc',
  time_series_data_col = 'load_mw',
  data_frequency = 'HOURLY',
  holiday_region = 'US',
  auto_arima = TRUE,
  horizon = 48
) AS
SELECT interval_start_utc, load_mw, tavg_f, hdd65, cdd65
FROM `${project}.mart.load_weather_hourly`
WHERE interval_start_utc >= ${train_start}
  AND interval_start_utc < ${train_end}
  AND load_mw IS NOT NULL
  AND tavg_f IS NOT NULL;
