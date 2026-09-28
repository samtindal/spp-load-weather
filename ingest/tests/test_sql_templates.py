"""Every file in sql/ must render with exactly the variables its callers pass.

Terraform's templatefile() renders the same files for the scheduled queries
and views; `terraform validate` doesn't evaluate them, so this is where a
missing or misspelled ${var} gets caught before an apply.
"""

import re
from pathlib import Path

import pytest

from spp_load_weather.sql import render

SQL = Path(__file__).parents[2] / "sql"

CASES = {
    "staging_load_hourly.sql": {"project": "p"},
    "staging_weather_stations.sql": {"project": "p", "start_year": "2021", "end_year": "2026", "n_stations": "5"},
    "staging_weather_daily.sql": {"project": "p", "start_year": "2021", "end_year": "9999"},
    "mart_load_weather_daily.sql": {"project": "p"},
    "mart_load_weather_hourly.sql": {"project": "p"},
    "models/arima_plus_xreg.sql": {"project": "p", "model_name": "m", "train_start": "x", "train_end": "y"},
}

DML = re.compile(r"^\s*(MERGE|INSERT|UPDATE|DELETE|TRUNCATE)\b", re.IGNORECASE | re.MULTILINE)


def test_every_sql_file_has_a_case():
    assert {str(p.relative_to(SQL)) for p in SQL.rglob("*.sql")} == set(CASES)


@pytest.mark.parametrize("name", sorted(CASES))
def test_renders_without_leftover_placeholders(name):
    text = render(SQL / name, **CASES[name])
    assert "${" not in text


@pytest.mark.parametrize("name", sorted(CASES))
def test_no_dml_so_everything_runs_in_the_bigquery_sandbox(name):
    assert not DML.search(render(SQL / name, **CASES[name]))


@pytest.mark.parametrize("name", ["staging_weather_stations.sql", "staging_weather_daily.sql"])
def test_gsod_suffix_is_filtered_by_constants(name):
    text = render(SQL / name, **CASES[name])
    assert re.search(r"_TABLE_SUFFIX BETWEEN '\d{4}' AND '\d{4}'", text)
