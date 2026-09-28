"""Every file in sql/ must render with exactly the variables its callers pass.

Terraform's templatefile() renders the same files for the scheduled queries
and views; `terraform validate` doesn't evaluate them, so this is where a
missing or misspelled ${var} gets caught before an apply.
"""

from pathlib import Path

import pytest

from spp_load_weather.sql import render

SQL = Path(__file__).parents[2] / "sql"

CASES = {
    "staging_load_hourly.sql": {"project": "p", "since": "DATE '2021-01-01'"},
    "staging_weather_stations.sql": {"project": "p", "start_year": "2021", "end_year": "2026", "n_stations": "5"},
    "staging_weather_daily.sql": {"project": "p", "start_date": "DATE '2021-01-01'", "end_date": "CURRENT_DATE()"},
    "mart_load_weather_daily.sql": {"project": "p"},
    "mart_load_weather_hourly.sql": {"project": "p"},
    "models/arima_plus_xreg.sql": {"project": "p", "model_name": "m", "train_start": "x", "train_end": "y"},
}


def test_every_sql_file_has_a_case():
    assert {str(p.relative_to(SQL)) for p in SQL.rglob("*.sql")} == set(CASES)


@pytest.mark.parametrize("name", sorted(CASES))
def test_renders_without_leftover_placeholders(name):
    text = render(SQL / name, **CASES[name])
    assert "${" not in text
    assert "`p." in text


def test_weather_year_range_is_spliced_as_a_literal():
    text = render(SQL / "staging_weather_daily.sql", **CASES["staging_weather_daily.sql"])
    assert "_TABLE_SUFFIX BETWEEN '%s' AND '%s'" in text
    assert "EXECUTE IMMEDIATE FORMAT(" in text
