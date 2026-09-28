"""Render and run the SQL files under sql/.

The files use `${name}` placeholders so the same text works with Terraform's
templatefile() (scheduled queries and views) and with string.Template here
(the backfill). substitute() raises on a missing variable, and so does
templatefile(), so a typo fails loudly in both places.

Staging files are plain SELECTs. The runner, not the SQL, decides where the
result goes: a destination table with WRITE_TRUNCATE. That is a query job,
not DML, so it runs in the BigQuery sandbox, and the scheduled-query version
(destination_table_name_template + WRITE_TRUNCATE) does the same thing.
"""

from __future__ import annotations

import logging
from pathlib import Path
from string import Template

from google.cloud import bigquery

log = logging.getLogger(__name__)


def render(path: str | Path, **variables: str) -> str:
    return Template(Path(path).read_text()).substitute(variables)


def query_config(*, max_bytes_billed: int, destination: str | None = None) -> bigquery.QueryJobConfig:
    config = bigquery.QueryJobConfig(maximum_bytes_billed=max_bytes_billed, use_legacy_sql=False)
    if destination:
        config.destination = bigquery.TableReference.from_string(destination)
        config.write_disposition = bigquery.WriteDisposition.WRITE_TRUNCATE
    return config


def run(
    sql: str,
    *,
    project: str,
    max_bytes_billed: int,
    destination: str | None = None,
    location: str = "US",
) -> int:
    """Run one SQL statement with a hard cap on billed bytes. Returns bytes processed."""
    client = bigquery.Client(project=project, location=location)
    job = client.query(sql, job_config=query_config(max_bytes_billed=max_bytes_billed, destination=destination))
    job.result()
    processed = job.total_bytes_processed or 0
    log.info(
        "job %s processed %.1f MiB (billed %.1f MiB)%s",
        job.job_id,
        processed / 2**20,
        (job.total_bytes_billed or 0) / 2**20,
        f" -> {destination}" if destination else "",
    )
    return processed
