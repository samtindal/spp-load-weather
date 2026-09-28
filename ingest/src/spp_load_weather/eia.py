"""Minimal EIA API v2 client for the RTO region-data route.

The API caps every response at 5,000 rows, so any real date range has to be
paged with `offset`/`length`. An implementation that ignores that silently
truncates, which is why the client checks the rows it received against the
`total` the API reports and refuses to return a partial result.
"""

from __future__ import annotations

import logging
import re
import time
from collections.abc import Callable, Sequence
from datetime import datetime
from typing import Any

import requests

log = logging.getLogger(__name__)

BASE_URL = "https://api.eia.gov/v2/"
REGION_DATA_ROUTE = "electricity/rto/region-data/data/"
MAX_PAGE_SIZE = 5000
RETRYABLE_STATUS = frozenset({429, 500, 502, 503, 504})
PERIOD_FORMAT = "%Y-%m-%dT%H"  # EIA's hourly format, YYYY-MM-DD"T"HH24, in UTC


class EIAError(RuntimeError):
    """The API returned an error, or retries ran out."""


class TruncationError(EIAError):
    """Pagination ended with fewer rows than the API said exist."""


class EIAClient:
    def __init__(
        self,
        api_key: str,
        *,
        session: Any = None,
        page_size: int = MAX_PAGE_SIZE,
        max_retries: int = 5,
        backoff_base: float = 2.0,
        timeout: float = 60.0,
        sleep: Callable[[float], None] = time.sleep,
    ):
        if not 1 <= page_size <= MAX_PAGE_SIZE:
            raise ValueError(f"page_size must be between 1 and {MAX_PAGE_SIZE}")
        self._api_key = api_key
        self._session = session or requests.Session()
        self._page_size = page_size
        self._max_retries = max_retries
        self._backoff_base = backoff_base
        self._timeout = timeout
        self._sleep = sleep

    def fetch_region_data(
        self,
        respondent: str,
        types: Sequence[str],
        start: datetime,
        end: datetime,
    ) -> list[dict[str, Any]]:
        """Return every hourly row for `respondent` and `types` in [start, end], UTC.

        `respondent` is the EIA balancing-authority code: Southwest Power Pool
        is "SWPP", not "SPP".
        """
        base = [
            ("frequency", "hourly"),
            ("data[0]", "value"),
            ("facets[respondent][]", respondent),
            *(("facets[type][]", t) for t in types),
            ("start", start.strftime(PERIOD_FORMAT)),
            ("end", end.strftime(PERIOD_FORMAT)),
            # A total order, so offset paging never skips or repeats a row.
            ("sort[0][column]", "period"),
            ("sort[0][direction]", "asc"),
            ("sort[1][column]", "type"),
            ("sort[1][direction]", "asc"),
        ]

        rows: list[dict[str, Any]] = []
        total: int | None = None
        while total is None or len(rows) < total:
            payload = self._get(base + [("offset", len(rows)), ("length", self._page_size)])
            body = payload["response"]
            total = int(body["total"])
            batch = body.get("data") or []
            if not batch:
                break
            rows.extend(batch)
            log.info("fetched %d/%d rows", len(rows), total)

        if total is not None and len(rows) != total:
            raise TruncationError(f"expected {total} rows, got {len(rows)}")
        return rows

    def _get(self, params: list[tuple[str, Any]]) -> dict[str, Any]:
        url = BASE_URL + REGION_DATA_ROUTE
        params = [("api_key", self._api_key), *params]

        for attempt in range(self._max_retries + 1):
            last_attempt = attempt == self._max_retries
            try:
                resp = self._session.get(url, params=params, timeout=self._timeout)
            except (requests.ConnectionError, requests.Timeout) as exc:
                if last_attempt:
                    raise EIAError(self._redact(f"request failed: {exc}")) from None
                self._backoff(attempt, self._redact(str(exc)))
                continue

            if resp.status_code in RETRYABLE_STATUS and not last_attempt:
                self._backoff(attempt, f"HTTP {resp.status_code}")
                continue
            if resp.status_code != 200:
                raise EIAError(self._redact(f"HTTP {resp.status_code}: {resp.text[:500]}"))

            payload = resp.json()
            if "error" in payload:
                raise EIAError(self._redact(f"API error: {payload['error']}"))
            for warning in payload.get("response", {}).get("warnings", []) or []:
                log.warning("EIA warning: %s", warning)
            return payload

        raise AssertionError("unreachable")  # pragma: no cover

    def _backoff(self, attempt: int, reason: str) -> None:
        delay = self._backoff_base * (2**attempt)
        log.warning("retrying in %.1fs after %s", delay, reason)
        self._sleep(delay)

    def _redact(self, text: str) -> str:
        """Request URLs carry the key as a query parameter; never let it reach a log."""
        text = text.replace(self._api_key, "***")
        return re.sub(r"api_key=[^&\s'\"]+", "api_key=***", text)
