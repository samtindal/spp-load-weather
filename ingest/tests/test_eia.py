from datetime import datetime

import pytest
import requests
from conftest import FakeResponse, FakeSession, make_rows, page

from spp_load_weather.eia import EIAClient, EIAError, TruncationError

START = datetime(2024, 1, 1, 0)
END = datetime(2024, 1, 1, 23)


def client(session, no_sleep, **kw):
    return EIAClient("SECRET-KEY", session=session, sleep=no_sleep.append, **kw)


def params_of(call):
    return call["params"]


def test_request_uses_swpp_respondent_and_both_series(no_sleep, recorded_page):
    session = FakeSession([FakeResponse(200, recorded_page)])
    client(session, no_sleep).fetch_region_data("SWPP", ["D", "DF"], START, END)

    params = params_of(session.calls[0])
    assert session.calls[0]["url"] == "https://api.eia.gov/v2/electricity/rto/region-data/data/"
    assert ("facets[respondent][]", "SWPP") in params
    assert ("facets[type][]", "D") in params
    assert ("facets[type][]", "DF") in params
    assert ("frequency", "hourly") in params
    assert ("data[0]", "value") in params
    assert ("start", "2024-01-01T00") in params
    assert ("end", "2024-01-01T23") in params


def test_sort_is_fully_deterministic_so_offsets_are_stable(no_sleep, recorded_page):
    session = FakeSession([FakeResponse(200, recorded_page)])
    client(session, no_sleep).fetch_region_data("SWPP", ["D", "DF"], START, END)

    params = params_of(session.calls[0])
    assert ("sort[0][column]", "period") in params
    assert ("sort[1][column]", "type") in params


def test_recorded_page_parses(no_sleep, recorded_page):
    session = FakeSession([FakeResponse(200, recorded_page)])
    rows = client(session, no_sleep).fetch_region_data("SWPP", ["D", "DF"], START, END)
    assert len(rows) == 4
    assert {r["type"] for r in rows} == {"D", "DF"}


def test_paginates_by_offset_until_total_is_reached(no_sleep):
    session = FakeSession([page(make_rows(2, 0), 5), page(make_rows(2, 2), 5), page(make_rows(1, 4), 5)])
    rows = client(session, no_sleep, page_size=2).fetch_region_data("SWPP", ["D"], START, END)

    assert len(rows) == 5
    offsets = [dict(c["params"])["offset"] for c in session.calls]
    lengths = {dict(c["params"])["length"] for c in session.calls}
    assert offsets == [0, 2, 4]
    assert lengths == {2}


def test_page_size_cannot_exceed_api_maximum():
    with pytest.raises(ValueError):
        EIAClient("k", page_size=5001)


def test_short_page_before_total_raises_truncation(no_sleep):
    session = FakeSession([page(make_rows(2, 0), 5), page([], 5)])
    with pytest.raises(TruncationError, match="expected 5 rows, got 2"):
        client(session, no_sleep, page_size=2).fetch_region_data("SWPP", ["D"], START, END)


def test_retries_transient_status_with_exponential_backoff(no_sleep):
    session = FakeSession([FakeResponse(429, {}), FakeResponse(503, {}), page(make_rows(1), 1)])
    rows = client(session, no_sleep, backoff_base=1.0).fetch_region_data("SWPP", ["D"], START, END)

    assert len(rows) == 1
    assert no_sleep == [1.0, 2.0]


def test_retries_connection_errors(no_sleep):
    session = FakeSession([requests.ConnectionError("boom"), page(make_rows(1), 1)])
    rows = client(session, no_sleep).fetch_region_data("SWPP", ["D"], START, END)
    assert len(rows) == 1


def test_gives_up_after_max_retries(no_sleep):
    session = FakeSession([FakeResponse(503, {})] * 3)
    with pytest.raises(EIAError, match="503"):
        client(session, no_sleep, max_retries=2).fetch_region_data("SWPP", ["D"], START, END)
    assert len(session.calls) == 3


def test_client_errors_are_not_retried(no_sleep):
    session = FakeSession([FakeResponse(403, {"error": "invalid api_key"})])
    with pytest.raises(EIAError, match="403"):
        client(session, no_sleep).fetch_region_data("SWPP", ["D"], START, END)
    assert len(session.calls) == 1


def test_api_key_never_appears_in_error_messages(no_sleep):
    leaky = requests.ConnectionError("failed: https://api.eia.gov/v2/x?api_key=SECRET-KEY&offset=0")
    session = FakeSession([leaky] * 2)
    with pytest.raises(EIAError) as exc:
        client(session, no_sleep, max_retries=1).fetch_region_data("SWPP", ["D"], START, END)
    assert "SECRET-KEY" not in str(exc.value)
    assert "SECRET-KEY" not in repr(exc.value.__cause__)


def test_error_payload_on_200_is_an_error(no_sleep):
    session = FakeSession([FakeResponse(200, {"error": "Invalid facet"})])
    with pytest.raises(EIAError, match="Invalid facet"):
        client(session, no_sleep).fetch_region_data("SWPP", ["D"], START, END)
