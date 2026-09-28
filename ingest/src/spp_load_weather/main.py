"""Entrypoint for the backfill (local) and the scheduled Cloud Run Job.

    spp-load-weather ingest --start 2021-01-01 --end 2025-12-31 --dest data/ --table P.raw.eia_region_data
    spp-load-weather ingest --dest gs://BUCKET --table P.raw.eia_region_data      # last 3 days
    spp-load-weather run-sql sql/staging_load_hourly.sql --project P --destination P.staging.load_hourly

Failure safety: every page is fetched and the row count checked before
anything is written, and the write is a single BigQuery load job, which is
atomic. A failed EIA call therefore leaves the table exactly as it was.

Idempotency: raw is an append-only landing table (a re-run lands the same
rows again, tagged with a later `ingested_at`). The staging rebuild keeps
only the latest copy of each (period, type), so re-running a window never
duplicates a row downstream.

Cost: BigQuery batch load jobs are free; streaming inserts are not. That is
why this writes a file and loads it, not tabledata.insertAll.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

from spp_load_weather import sql
from spp_load_weather.eia import EIAClient
from spp_load_weather.records import to_ndjson, to_raw_record

log = logging.getLogger("spp_load_weather")

DEFAULT_TYPES = ("D", "DF")  # demand, and EIA's own day-ahead demand forecast
DEFAULT_MAX_BYTES = 4 * 2**30  # 4 GiB per query: the GSOD weather rebuild reads a few GiB of columns


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="spp-load-weather")
    sub = parser.add_subparsers(dest="command", required=True)

    ingest = sub.add_parser("ingest", help="EIA API -> NDJSON file -> BigQuery raw table")
    ingest.add_argument("--respondent", default="SWPP")
    ingest.add_argument("--types", nargs="+", default=list(DEFAULT_TYPES))
    ingest.add_argument("--start", type=date.fromisoformat, help="first UTC day (inclusive)")
    ingest.add_argument("--end", type=date.fromisoformat, help="last UTC day (inclusive)")
    ingest.add_argument(
        "--lookback-days", type=int, default=3, help="window when --start is omitted; EIA revises recent hours"
    )
    ingest.add_argument("--dest", required=True, help="gs://bucket[/prefix] or a local directory")
    ingest.add_argument("--table", required=True, help="project.dataset.table for the raw landing table")
    ingest.add_argument("--no-load", action="store_true", help="write the file only")

    run_sql = sub.add_parser("run-sql", help="render a sql/ file and run it with a byte cap")
    run_sql.add_argument("path", type=Path)
    run_sql.add_argument("--project", required=True)
    run_sql.add_argument("--var", action="append", default=[], metavar="NAME=VALUE")
    run_sql.add_argument("--max-bytes-billed", type=int, default=DEFAULT_MAX_BYTES)
    run_sql.add_argument("--destination", help="project.dataset.table to overwrite with the result")

    return parser.parse_args(argv)


def resolve_window(args: argparse.Namespace, now: datetime) -> tuple[datetime, datetime]:
    current_hour = now.astimezone(UTC).replace(minute=0, second=0, microsecond=0)
    if args.start:
        start = datetime.combine(args.start, datetime.min.time(), tzinfo=UTC)
    else:
        start = (current_hour - timedelta(days=args.lookback_days)).replace(hour=0)
    if args.end:
        end = datetime.combine(args.end, datetime.min.time(), tzinfo=UTC).replace(hour=23)
    else:
        end = current_hour
    if start > end:
        sys.exit(f"start {start:%Y-%m-%d} is after end {end:%Y-%m-%d}")
    return start, end


def landing_name(respondent: str, start: datetime, end: datetime, now: datetime) -> str:
    return (
        f"eia/region-data/respondent={respondent}/ingest_date={now:%Y-%m-%d}/"
        f"{start:%Y%m%d%H}_{end:%Y%m%d%H}_{now:%Y%m%dT%H%M%SZ}.ndjson"
    )


def landing_uri(dest: str, name: str) -> str:
    return f"{dest.rstrip('/')}/{name}" if dest.startswith("gs://") else str(Path(dest) / name)


def _write(uri: str, body: str) -> None:
    if uri.startswith("gs://"):
        from google.cloud import storage

        bucket_name, _, blob_name = uri.removeprefix("gs://").partition("/")
        storage.Client().bucket(bucket_name).blob(blob_name).upload_from_string(
            body, content_type="application/x-ndjson"
        )
        return
    path = Path(uri)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)


def _load(uri: str, table: str, expected_rows: int) -> None:
    from google.cloud import bigquery

    project = table.split(".")[0]
    client = bigquery.Client(project=project)
    config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
        # The table's schema is owned by Terraform; never let a load job alter it.
        schema=client.get_table(table).schema,
        ignore_unknown_values=False,
    )
    if uri.startswith("gs://"):
        job = client.load_table_from_uri(uri, table, job_config=config)
    else:
        with open(uri, "rb") as fh:
            job = client.load_table_from_file(fh, table, job_config=config)
    job.result()
    if job.output_rows != expected_rows:
        raise RuntimeError(f"load wrote {job.output_rows} rows, expected {expected_rows}")
    log.info("loaded %d rows into %s", job.output_rows, table)


def ingest(args: argparse.Namespace) -> None:
    api_key = os.environ.get("EIA_API_KEY")
    if not api_key:
        sys.exit("EIA_API_KEY is not set")

    now = datetime.now(UTC)
    start, end = resolve_window(args, now)
    log.info("fetching %s %s from %s to %s", args.respondent, args.types, start, end)

    rows = EIAClient(api_key).fetch_region_data(args.respondent, args.types, start, end)
    if not rows:
        log.info("no rows returned; nothing to load")
        return

    uri = landing_uri(args.dest, landing_name(args.respondent, start, end, now))
    _write(uri, to_ndjson(to_raw_record(r, now, uri) for r in rows))
    log.info("wrote %d rows to %s", len(rows), uri)

    if not args.no_load:
        _load(uri, args.table, expected_rows=len(rows))


def main(argv: list[str] | None = None) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    args = parse_args(argv)
    if args.command == "ingest":
        ingest(args)
    elif args.command == "run-sql":
        variables = {"project": args.project} | dict(v.split("=", 1) for v in args.var)
        sql.run(
            sql.render(args.path, **variables),
            project=args.project,
            max_bytes_billed=args.max_bytes_billed,
            destination=args.destination,
        )


if __name__ == "__main__":
    main()
