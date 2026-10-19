#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later WITH GPL-3.0-linking-exception
# Copyright (C) 2026 Yoonji Park <koreapyj@dcmys.kr>
#
# Prepare an upstream FastFlowLM source tree with our patches applied.
#
#   support/prepare-source.sh <dir>
#
# 1. <dir> gets upstream FastFlowLM at FLM_REF (support/upstream.env) with its tags, so
#    `git describe` works as in upstream's own CI. An existing checkout is reused
#    (fetched and checked out) unless it has local changes.
# 2. Submodules (tokenizers-cpp and its own) are initialized.
# 3. The prebuilt engine libraries and xclbins are checked against
#    support/pinned-binaries.sha256 (the Qwen3-TTS fast path depends on their internals).
# 4. patches/*.patch are git-applied; a patch that is already applied is skipped
#    (NO_PATCHES=1: not applied).
#
# Used by CI (.github/workflows/*) and by the Makefile.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
dir="${1:?usage: prepare-source.sh <dir>}"
# shellcheck source=upstream.env
source "$here/upstream.env"
FLM_REF="${FLM_REF_OVERRIDE:-$FLM_REF}"

mkdir -p "$dir"
cd "$dir"
# CI containers run as root on a workspace owned by another uid: git refuses to work in
# it (and in the submodules it creates) until told it is safe. Before any git command.
if [ -n "${CI:-}" ]; then git config --global --add safe.directory '*'; fi
if [ ! -d .git ]; then
    # init + fetch instead of clone: <dir> may be non-empty (CI checks this repository
    # out into a subdirectory of the workspace the upstream tree goes to)
    git init -q
    git remote add origin "$FLM_REPO"
fi
if git rev-parse -q --verify HEAD >/dev/null && ! git diff --quiet HEAD --; then
    echo "prepare-source: $dir has local changes; not touching the checkout" >&2
else
    echo "prepare-source: fetching $FLM_REPO at $FLM_REF"
    git fetch -q --tags origin
    git fetch -q origin "$FLM_REF"
    git -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
fi
describe="$(git describe --tags --always)"
echo "prepare-source: upstream is $describe"
if [ -z "${FLM_REF_OVERRIDE:-}" ] && [ "$describe" != "$FLM_DESCRIBE" ]; then
    echo "prepare-source: upstream describes as $describe, support/upstream.env says FLM_DESCRIBE=$FLM_DESCRIBE;" >&2
    echo "update FLM_DESCRIBE (release tags and package versions are derived from it)" >&2
    exit 1
fi
if ! grep -v '^#' "$here/upstream-workflows.sha256" | sha256sum --quiet -c - >/dev/null 2>&1; then
    msg="upstream build workflows at $FLM_REF differ from the ones .github/workflows was generated from; run support/sync-workflows.py"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::$msg"; else echo "prepare-source: warning: $msg" >&2; fi
fi

git submodule sync -q --recursive
git submodule update -q --init --recursive --depth 1 || git submodule update -q --init --recursive

echo "prepare-source: checking pinned engine binaries"
if ! grep -v '^#' "$here/pinned-binaries.sha256" | sha256sum --quiet -c -; then
    echo "prepare-source: the prebuilt qwen3_npu engine binaries at $FLM_REF differ from the" >&2
    echo "validated ones (support/pinned-binaries.sha256). The Qwen3-TTS integration must be" >&2
    echo "revalidated on the NPU before this ref can be used; see README 'Updating FLM_REF'." >&2
    exit 1
fi

shopt -s nullglob
[ -n "${NO_PATCHES:-}" ] && { echo "prepare-source: ready (NO_PATCHES: patches not applied)"; exit 0; }
for p in "$root"/patches/*.patch; do
    name="$(basename "$p")"
    if git apply --reverse --check "$p" >/dev/null 2>&1; then
        echo "prepare-source: $name already applied"
    else
        echo "prepare-source: applying $name"
        git apply "$p"
    fi
done
echo "prepare-source: ready"
