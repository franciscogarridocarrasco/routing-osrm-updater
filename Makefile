SHELL := /bin/bash

PROJECT_ROOT ?= .
ENV_FILE ?= $(PROJECT_ROOT)/.env
UPDATER_REGIONS_FILE ?= config/regions/local.txt
UPDATER_COMPOSE_FILE ?= compose.yaml
COMPOSE := docker compose -f compose.yaml --env-file $(ENV_FILE)

.PHONY: config build-tools download-strict merge-local build-graph-local publish-version update-dataset

config:
	$(COMPOSE) config --quiet

build-tools:
	$(COMPOSE) --profile tools build data-tools

download-strict:
	$(COMPOSE) --profile tools run --rm \
		-e ALLOW_STALE_DATASET=false \
		data-tools \
		./scripts/download.sh $(UPDATER_REGIONS_FILE)

merge-local:
	$(COMPOSE) --profile tools run --rm data-tools \
		./scripts/merge.sh \
		data/work/raw \
		data/work/merged/region.osm.pbf

build-graph-local:
	COMPOSE_FILE=$(UPDATER_COMPOSE_FILE) \
		./scripts/build-graph.sh data/work/merged/region.osm.pbf

publish-version:
	@test -n "$(DATASET_VERSION)" || \
		(echo "DATASET_VERSION is required" && exit 1)
	$(PROJECT_ROOT)/scripts/publish-dataset.sh \
		data/work/merged \
		"$(DATASET_VERSION)" \
		data/releases

update-dataset:
	$(PROJECT_ROOT)/update-dataset.sh "$(DATASET_VERSION)"
