#!/usr/bin/env bash
#
# Regenerate patches/*.patch from the working tree of an upstream checkout.
#
#   support/update-patches.sh [<dir>]     (default: src)
#
# Each patch is `git diff FLM_REF` of its own paths (committed and uncommitted changes
# alike), so the patches stay independent: they never touch the same file. The
# description before the first "diff --git" line of the existing patch is kept.
#   0002-qwen3-tts-package-tools.patch  src/tools/qwen3_tts
#   0001-qwen3-tts-npu.patch            everything else
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
dir="${1:-$root/src}"
source "$here/upstream.env"
tools='src/tools/qwen3_tts'

header() { sed -n '/^diff --git /q;p' "$1"; }
write() {
    local out="$root/patches/$1"; shift
    local h; h="$(header "$out" 2>/dev/null || true)"
    { [ -n "$h" ] && printf '%s\n\n' "$h"; git -C "$dir" diff --no-color "$FLM_REF" -- "$@"; } > "$out.tmp"
    mv "$out.tmp" "$out"
    echo "updated patches/$(basename "$out") ($(grep -c '^diff --git ' "$out") files)"
}
write 0001-qwen3-tts-npu.patch . ":!$tools"
write 0002-qwen3-tts-package-tools.patch "$tools"
