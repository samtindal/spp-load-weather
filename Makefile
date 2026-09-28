# spp-load-weather
#
#   make init-sandbox   BigQuery sandbox (no billing): local state, warehouse only
#   make bootstrap   one-time, billing mode: state bucket (local state)
#   make init        billing mode: point the main stack at that bucket
#   make plan / apply / destroy
#   make backfill    load five years of SPP load + weather (Phase 1)
#   make notebook    open the analysis
#   make image deploy   build + push the ingestion image, roll it out (Phase 2)
#   make check       everything CI runs

SHELL := /bin/bash

TF      := terraform -chdir=terraform
PROJECT ?= $(shell sed -n 's/^project_id *= *"\(.*\)"/\1/p' terraform/terraform.tfvars 2>/dev/null)
REGION  ?= us-central1

START ?= 2021-01-01
END   ?= $(shell python3 -c 'import datetime as d; print(d.date.today() - d.timedelta(days=1))')
START_YEAR = $(firstword $(subst -, ,$(START)))
END_YEAR   = $(firstword $(subst -, ,$(END)))
N_STATIONS ?= 5

RUN := cd ingest && uv run spp-load-weather
IMAGE_TAG ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
IMAGE      = $(REGION)-docker.pkg.dev/$(PROJECT)/spp-load-weather/ingest:$(IMAGE_TAG)

.PHONY: help bootstrap init init-sandbox plan apply destroy backfill backfill-load backfill-weather notebook notebook-run \
        image deploy fmt lint test check require-project

help:
	@sed -n 's/^#   //p' Makefile

require-project:
	@test -n "$(PROJECT)" || { echo "Set project_id in terraform/terraform.tfvars or pass PROJECT=..."; exit 1; }

# --- Infrastructure -----------------------------------------------------------------

bootstrap: require-project
	terraform -chdir=terraform/bootstrap init -input=false
	terraform -chdir=terraform/bootstrap apply -var project_id=$(PROJECT) -var region=$(REGION)

init: require-project
	rm -f terraform/backend_override.tf
	$(TF) init -input=false -reconfigure -backend-config=bucket=$(PROJECT)-tfstate

# The sandbox can't create a Cloud Storage bucket, so state stays local.
# Terraform's override-file mechanism swaps the gcs backend for local
# without editing committed config; the override file is gitignored.
init-sandbox:
	printf 'terraform {\n  backend "local" {}\n}\n' > terraform/backend_override.tf
	$(TF) init -input=false -reconfigure

plan:
	$(TF) plan -out=tfplan

apply:
	$(TF) apply tfplan

destroy:
	$(TF) destroy

# --- Phase 1 data load ---------------------------------------------------------------
# The same package and SQL the Phase 2 schedule runs, with a fixed window.
# Every SQL step runs with maximum_bytes_billed (default 4 GiB) and overwrites its
# staging table (WRITE_TRUNCATE), so re-running is always safe.

backfill: backfill-load backfill-weather

backfill-load: require-project
	@test -n "$$EIA_API_KEY" || { echo "export EIA_API_KEY first (free key: eia.gov/opendata)"; exit 1; }
	$(RUN) ingest --start $(START) --end $(END) --dest ../data --table $(PROJECT).raw.eia_region_data
	$(RUN) run-sql ../sql/staging_load_hourly.sql --project $(PROJECT) --destination $(PROJECT).staging.load_hourly

backfill-weather: require-project
	$(RUN) run-sql ../sql/staging_weather_stations.sql --project $(PROJECT) \
	  --destination $(PROJECT).staging.weather_stations \
	  --var start_year=$(START_YEAR) --var end_year=$(END_YEAR) --var n_stations=$(N_STATIONS)
	$(RUN) run-sql ../sql/staging_weather_daily.sql --project $(PROJECT) \
	  --destination $(PROJECT).staging.weather_daily \
	  --var start_year=$(START_YEAR) --var end_year=$(END_YEAR)

# --- Analysis ---------------------------------------------------------------------------

notebook: require-project
	cd ingest && uv sync --group notebook && \
	  GOOGLE_CLOUD_PROJECT=$(PROJECT) uv run --group notebook jupyter lab --notebook-dir=../notebooks

# Execute top to bottom in a fresh kernel and save outputs in place (they get committed).
notebook-run: require-project
	cd ingest && uv sync --group notebook && cd ../notebooks && \
	  GOOGLE_CLOUD_PROJECT=$(PROJECT) uv run --project ../ingest --group notebook \
	  jupyter nbconvert --to notebook --execute --inplace --ExecutePreprocessor.timeout=3600 \
	  01_load_weather_analysis.ipynb

# --- Phase 2 image ----------------------------------------------------------------------

image: require-project
	gcloud auth configure-docker $(REGION)-docker.pkg.dev --quiet
	docker build --platform linux/amd64 -t $(IMAGE) ingest
	docker push $(IMAGE)

deploy:
	$(TF) apply -var ingestion_image=$(IMAGE)

# --- Quality ------------------------------------------------------------------------------

fmt:
	terraform fmt -recursive terraform
	cd ingest && uv run ruff format . && uv run ruff check --fix .

lint:
	terraform fmt -check -recursive terraform
	$(TF) init -backend=false -input=false >/dev/null && $(TF) validate
	terraform -chdir=terraform/bootstrap init -backend=false -input=false >/dev/null && terraform -chdir=terraform/bootstrap validate
	@if command -v tflint >/dev/null; then cd terraform && tflint --init && tflint --recursive --config "$$PWD/.tflint.hcl"; \
	  else echo "tflint not installed; skipping (CI runs it)"; fi
	cd ingest && uv run ruff check . && uv run ruff format --check .

test:
	cd ingest && uv run pytest

check: lint test
