from datetime import UTC, datetime

import pytest

from spp_load_weather.main import landing_name, parse_args, resolve_window
from spp_load_weather.sql import render

NOW = datetime(2026, 9, 28, 14, 37, tzinfo=UTC)


def test_default_window_is_lookback_from_current_hour():
    args = parse_args(["ingest", "--dest", "data/", "--table", "p.raw.t"])
    start, end = resolve_window(args, now=NOW)

    assert end == datetime(2026, 9, 28, 14, tzinfo=UTC)
    assert start == datetime(2026, 9, 25, 0, tzinfo=UTC)


def test_explicit_window_covers_whole_end_day():
    args = parse_args(["ingest", "--start", "2021-01-01", "--end", "2025-12-31", "--dest", "d/", "--table", "p.r.t"])
    start, end = resolve_window(args, now=NOW)

    assert start == datetime(2021, 1, 1, 0, tzinfo=UTC)
    assert end == datetime(2025, 12, 31, 23, tzinfo=UTC)


def test_start_after_end_is_rejected():
    args = parse_args(["ingest", "--start", "2025-01-02", "--end", "2025-01-01", "--dest", "d/", "--table", "p.r.t"])
    with pytest.raises(SystemExit):
        resolve_window(args, now=NOW)


def test_landing_name_is_deterministic_for_a_window():
    start = datetime(2021, 1, 1, tzinfo=UTC)
    end = datetime(2025, 12, 31, 23, tzinfo=UTC)
    name = landing_name("SWPP", start, end, NOW)

    assert name == (
        "eia/region-data/respondent=SWPP/ingest_date=2026-09-28/2021010100_2025123123_20260928T143700Z.ndjson"
    )


def test_render_substitutes_every_variable(tmp_path):
    f = tmp_path / "q.sql"
    f.write_text("SELECT * FROM `${project}.raw.t` WHERE d >= ${since}")
    assert render(f, project="p", since="DATE '2021-01-01'") == "SELECT * FROM `p.raw.t` WHERE d >= DATE '2021-01-01'"


def test_render_fails_loudly_on_missing_variable(tmp_path):
    f = tmp_path / "q.sql"
    f.write_text("SELECT ${missing}")
    with pytest.raises(KeyError):
        render(f)
