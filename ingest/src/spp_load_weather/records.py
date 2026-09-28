"""Shape EIA rows into the raw landing table's schema.

The raw layer keeps values as strings, exactly as received. Typing and
deduplication happen in SQL (sql/staging_load_hourly.sql), where they are
visible and testable, not here.
"""

from __future__ import annotations

import json
from collections.abc import Iterable
from datetime import datetime
from typing import Any

# Must match terraform/modules/warehouse/schemas/raw_eia_region_data.json (a test enforces it).
RAW_SCHEMA_FIELDS = (
    "period",
    "respondent",
    "respondent_name",
    "type",
    "type_name",
    "value",
    "value_units",
    "ingested_at",
    "ingest_date",
    "source_uri",
)


def _str_or_none(value: Any) -> str | None:
    return None if value is None else str(value)


def to_raw_record(row: dict[str, Any], ingested_at: datetime, source_uri: str) -> dict[str, Any]:
    return {
        "period": row["period"],
        "respondent": row["respondent"],
        "respondent_name": row.get("respondent-name"),
        "type": row["type"],
        "type_name": row.get("type-name"),
        "value": _str_or_none(row.get("value")),
        "value_units": row.get("value-units"),
        "ingested_at": ingested_at.isoformat(),
        "ingest_date": ingested_at.date().isoformat(),
        "source_uri": source_uri,
    }


def to_ndjson(records: Iterable[dict[str, Any]]) -> str:
    return "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in records)
