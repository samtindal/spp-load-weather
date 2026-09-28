# Same package the local backfill runs, containerized for the Cloud Run Job.
FROM ghcr.io/astral-sh/uv:0.12.15 AS uv

FROM python:3.12-slim AS build
COPY --from=uv /uv /bin/uv
WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
# Dependencies first so code changes don't invalidate the layer. --frozen installs
# exactly what uv.lock pins (with hashes); --no-dev skips pytest/ruff.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src ./src
RUN uv sync --frozen --no-dev

FROM python:3.12-slim
RUN useradd --system --uid 10001 app
COPY --from=build --chown=app /app /app
USER app
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1
ENTRYPOINT ["spp-load-weather"]
CMD ["ingest", "--help"]
