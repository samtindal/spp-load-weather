import json
from datetime import UTC, datetime

from spp_load_weather.records import RAW_SCHEMA_FIELDS, to_ndjson, to_raw_record

INGESTED = datetime(2026, 9, 28, 6, 0, tzinfo=UTC)


def test_values_are_normalized_to_strings_or_null(recorded_page):
    rows = recorded_page["response"]["data"]
    records = [to_raw_record(r, INGESTED, "gs://b/f.ndjson") for r in rows]

    assert [r["value"] for r in records] == ["51234", "50880", None, "51502"]


def test_record_carries_lineage_and_partition_column(recorded_page):
    rec = to_raw_record(recorded_page["response"]["data"][0], INGESTED, "gs://b/f.ndjson")

    assert rec["respondent_name"] == "Southwest Power Pool"
    assert rec["type_name"] == "Demand"
    assert rec["value_units"] == "megawatthours"
    assert rec["ingested_at"] == "2026-09-28T06:00:00+00:00"
    assert rec["ingest_date"] == "2026-09-28"
    assert rec["source_uri"] == "gs://b/f.ndjson"


def test_record_keys_match_the_raw_table_schema(recorded_page):
    rec = to_raw_record(recorded_page["response"]["data"][0], INGESTED, "x")
    assert tuple(rec) == RAW_SCHEMA_FIELDS


def test_raw_schema_matches_terraform_schema_file():
    """The loader and the Terraform-managed table must agree on columns."""
    from pathlib import Path

    schema_path = Path(__file__).parents[2] / "terraform/modules/warehouse/schemas/raw_eia_region_data.json"
    names = tuple(col["name"] for col in json.loads(schema_path.read_text()))
    assert names == RAW_SCHEMA_FIELDS


def test_ndjson_is_one_object_per_line(recorded_page):
    records = [to_raw_record(r, INGESTED, "x") for r in recorded_page["response"]["data"]]
    lines = to_ndjson(records).splitlines()

    assert len(lines) == 4
    assert all(json.loads(line)["respondent"] == "SWPP" for line in lines)
