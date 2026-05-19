# Build LXC image tarballs from distrobuilder recipes.
#
# Targets:
#   make help           Show this help
#   make all            Build every image under images/
#   make <image>        Build one image (e.g. `make service-base`)
#   make clean          Wipe output/
#   make lint           Run yamllint over the recipes
#
# Override PVE_HOST and PVE_STORAGE to point uploads at your Proxmox host:
#   make upload-service-base PVE_HOST=vaterland.local PVE_STORAGE=local

SHELL := /usr/bin/env bash

IMAGES := $(notdir $(wildcard images/*))
PVE_HOST ?=
PVE_STORAGE ?= local

.PHONY: help all clean lint $(IMAGES)

help:
	@echo "Available images:"
	@for img in $(IMAGES); do echo "  - $$img"; done
	@echo
	@echo "Targets:"
	@echo "  make all                  Build every image"
	@echo "  make <image>              Build one image"
	@echo "  make upload-<image>       Upload one image (set PVE_HOST=...)"
	@echo "  make clean                Wipe output/"
	@echo "  make lint                 yamllint the recipes"

all: $(IMAGES)

$(IMAGES):
	./scripts/build-image.sh $@

upload-%: %
	@if [[ -z "$(PVE_HOST)" ]]; then \
		echo "error: set PVE_HOST=<proxmox-hostname> (and optionally PVE_STORAGE)" >&2; \
		exit 2; \
	fi
	./scripts/upload-to-proxmox.sh $* $(PVE_HOST) $(PVE_STORAGE)

clean:
	rm -rf output/

lint:
	yamllint images/ .yamllint.yml lefthook.yml mise.toml 2>/dev/null || yamllint -c .yamllint.yml images/
