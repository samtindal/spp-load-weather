"""Shared test doubles. CI never talks to the EIA API.

`fixtures/region_data_page.json` follows the EIA API v2 response envelope
(response.total / response.data / request / apiVersion). Its `value` field
deliberately mixes strings, numbers, and nulls, because the live API is not
consistent about that and the loader must normalize all three.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

FIXTURES = Path(__file__).parent / "fixtures"


class FakeResponse:
    def __init__(self, status_code: int, payload: Any = None, text: str = ""):
        self.status_code = status_code
        self._payload = payload
        self.text = text or json.dumps(payload)

    def json(self) -> Any:
        return self._payload


class FakeSession:
    """Replays a scripted list of responses (or exceptions) and records every call."""

    def __init__(self, script: list[FakeResponse | Exception]):
        self.script = list(script)
        self.calls: list[dict[str, Any]] = []

    def get(self, url: str, params: Any = None, timeout: float | None = None) -> FakeResponse:
        self.calls.append({"url": url, "params": list(params or []), "timeout": timeout})
        item = self.script.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


def page(rows: list[dict[str, Any]], total: int) -> FakeResponse:
    return FakeResponse(200, {"response": {"total": str(total), "data": rows}})


def make_rows(n: int, start: int = 0) -> list[dict[str, Any]]:
    return [
        {
            "period": f"2024-01-01T{(start + i) % 24:02d}",
            "respondent": "SWPP",
            "respondent-name": "Southwest Power Pool",
            "type": "D",
            "type-name": "Demand",
            "value": str(30000 + start + i),
            "value-units": "megawatthours",
        }
        for i in range(n)
    ]


@pytest.fixture
def recorded_page() -> dict[str, Any]:
    return json.loads((FIXTURES / "region_data_page.json").read_text())


@pytest.fixture
def no_sleep() -> list[float]:
    """Collects requested backoff delays instead of sleeping."""
    return []
