"""Render and run the SQL files under sql/.

The files use `${name}` placeholders so the same text works with Terraform's
templatefile() (scheduled queries) and with string.Template here (the
one-time backfill). substitute() raises on a missing variable, and so does
templatefile(), so a typo fails loudly in both places.
"""

from __future__ import annotations

import logging
from pathlib import Path
from string import Template

log = logging.getLogger(__name__)


def render(path: str | Path, **variables: str) -> str:
    return Template(Path(path).read_text()).substitute(variables)


def run(sql: str, *, project: str, max_bytes_billed: int, location: str = "US") -> int:
    """Run one SQL script with a hard cap on billed bytes. Returns bytes processed."""
    from google.cloud import bigquery

    client = bigquery.Client(project=project, location=location)
    config = bigquery.QueryJobConfig(maximum_bytes_billed=max_bytes_billed, use_legacy_sql=False)
    job = client.query(sql, job_config=config)
    job.result()
    processed = job.total_bytes_processed or 0
    log.info(
        "job %s processed %.1f MiB (billed %.1f MiB)",
        job.job_id,
        processed / 2**20,
        (job.total_bytes_billed or 0) / 2**20,
    )
    return processed
