# SPDX-License-Identifier: GPL-3.0-or-later WITH GPL-3.0-linking-exception
# Copyright (C) 2026 Yoonji Park <koreapyj@dcmys.kr>
# Local workflow for developing the patches; CI does not use it (see .github/workflows).
# Builds run in upstream FastFlowLM's own CI image (plus Rust), like CI.

SHELL := /bin/bash
SRC      := src
DISTRO   ?= ubuntu26.04
BASE_IMAGE    ?= ghcr.io/rocm/fastflowlm/build-environment:$(DISTRO)
BUILDER_IMAGE ?= flm-builder:$(DISTRO)
ENGINE   ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
# docker writes as root unless told otherwise; rootless podman maps root to the caller
RUN_USER := $(if $(filter docker,$(ENGINE)),-u $(shell id -u):$(shell id -g),)
RUN      = $(ENGINE) run --rm $(RUN_USER) -v "$(CURDIR):/ws" -w /ws/$(SRC) $(BUILDER_IMAGE)

.DEFAULT_GOAL := help
.PHONY: help prepare image build test deb update sync-workflows check clean-build

help:
	@echo 'Local patch development (CI does not use this file).'
	@echo
	@echo '  prepare         upstream FastFlowLM at FLM_REF into $(SRC)/, pinned binaries checked, patches applied'
	@echo '  image           bake the builder image ($(BUILDER_IMAGE) from $(BASE_IMAGE))'
	@echo '  build           incremental build -> $(SRC)/src/build/flm'
	@echo '  test            Qwen3-TTS text segmentation unit tests'
	@echo '  deb             dpkg-buildpackage, as CI (-> ./fastflowlm_*.deb)'
	@echo '  update          regenerate patches/ from $(SRC)/ (git diff FLM_REF, split by path)'
	@echo '  check           each patch applies alone to a clean FLM_REF'
	@echo '  sync-workflows  regenerate .github/workflows/ from upstream'"'"'s at FLM_REF'
	@echo '  clean-build     remove $(SRC)/src/build'
	@echo
	@echo 'Variables: DISTRO (default $(DISTRO); ubuntu24.04 ubuntu25.10 ubuntu26.04 debian13), ENGINE ($(ENGINE))'

prepare:
	support/prepare-source.sh $(SRC)

image:
	$(ENGINE) build -f support/Dockerfile.builder --build-arg BASE=$(BASE_IMAGE) -t $(BUILDER_IMAGE) support/

build: image
	$(RUN) bash -c 'cd src && { [ -f build/build.ninja ] || cmake --preset linux-default; } && cmake --build build -j$$(nproc)'

test: image
	$(RUN) bash -c 'cmake -S src/test/qwen3_tts -B src/build-tts-test -G Ninja && cmake --build src/build-tts-test && src/build-tts-test/test_tts_text'

deb: image
	$(RUN) bash -c 'set -e; v=$$(git describe --tags --always | sed "s/^v//")+local; \
	  sed -e "s|@@DEB_VERSION@@|$$v|g" -e "s|@@DEB_CODENAME@@|local|g" -e "s|@@DEB_DATE@@|$$(date -R)|g" debian/changelog.in > debian/changelog; \
	  DEBEMAIL=noreply@example.com DEBFULLNAME=fastflowlm dpkg-buildpackage -b -us -uc; mv ../fastflowlm_*.deb /ws/'

update:
	support/update-patches.sh $(SRC)

check:
	@set -e; source support/upstream.env; w=$(CURDIR)/.tmp/patch-check; \
	rm -rf $$w; git -C $(SRC) worktree add -f -q $$w $$FLM_REF; \
	trap 'git -C $(SRC) worktree remove --force '$$w'' EXIT; \
	for p in patches/*.patch; do git -C $$w apply --check $(CURDIR)/$$p && echo "ok alone: $$p"; done; \
	for p in $$(ls patches/*.patch | sort -r); do git -C $$w apply $(CURDIR)/$$p; done; echo "ok all, reverse order"

sync-workflows:
	python3 support/sync-workflows.py $(SRC)

clean-build:
	rm -rf $(SRC)/src/build $(SRC)/src/build-tts-test
