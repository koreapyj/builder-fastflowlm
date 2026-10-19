#!/usr/bin/env python3
"""Generate .github/workflows/ from upstream FastFlowLM's own build workflows.

usage: support/sync-workflows.py [<upstream tree>]   (default: ./src, prepared at FLM_REF)

CI follows upstream: the build jobs are upstream's (.github/workflows/ubuntu-build.yml and
debian-portable.yml at FLM_REF), with only these changes:
  - triggers: every branch push, pull requests, manual runs (no tags of our own)
  - every actions/checkout step becomes: check this repository out into .builder/, then
    support/prepare-source.sh puts upstream FastFlowLM at FLM_REF (with our patches) in the
    workspace root, where upstream's steps expect their source
  - versions: `git describe` of upstream plus +g<this repository's commit>
  - releases: upstream releases when it pushes a tag; here every push to the default
    branch releases, tagged with upstream's version: <FLM_DESCRIBE>+g<commit>
Upstream's Windows workflows run on upstream's self-hosted runners and are not mirrored.
The hashes of the upstream files are recorded in support/upstream-workflows.sha256;
prepare-source.sh warns when FLM_REF's workflows no longer match (re-run this script).
"""
import hashlib, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = ["ubuntu-build.yml", "debian-portable.yml"]

TRIGGERS = """on:
  push:
    branches:
      - '**'
    paths-ignore:
      - '**/*.md'
  pull_request:
  workflow_dispatch:
"""


def checkout_steps(indent):
    p = " " * indent
    return [
        f"{p}- name: Checkout builder",
        f"{p}  uses: actions/checkout@v4",
        f"{p}  with:",
        f"{p}    path: .builder",
        f"",
        f"{p}- name: Prepare FastFlowLM source (upstream at FLM_REF + patches)",
        f"{p}  shell: bash",
        f"{p}  run: .builder/support/prepare-source.sh \"$GITHUB_WORKSPACE\"",
    ]


RELEASE_IF = "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"


def release_tag_step(p):
    return [
        f"{p}- name: Release tag",
        f"{p}  id: release_tag",
        f"{p}  shell: bash",
        f"{p}  run: |",
        f"{p}    source .builder/support/upstream.env",
        f"{p}    echo \"tag=$FLM_DESCRIBE+g${{GITHUB_SHA::7}}\" >> \"$GITHUB_OUTPUT\"",
        "",
    ]


def releases(lines):
    """jobs gated on a tag push: also run on default-branch pushes, upload to release_tag"""
    out, i, n = [], 0, 0
    while i < len(lines):
        out.append(lines[i])
        if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[i]):          # a job
            j = i + 1
            while j < len(lines) and not re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[j]) and not re.match(r"^\S", lines[j]):
                j += 1
            job = lines[i + 1:j]
            if any(l.strip() == "if: github.ref_type == 'tag'" for l in job):
                n += 1
                has_builder = any("path: .builder" in l for l in job)
                k = 0
                while k < len(job):
                    l = job[k]
                    if l.strip() == "if: github.ref_type == 'tag'":
                        l = l.replace("github.ref_type == 'tag'", RELEASE_IF)
                    l = l.replace("tag: ${{ github.ref }}", "tag: ${{ steps.release_tag.outputs.tag }}")
                    out.append(l)
                    if l.strip() == "steps:" and not has_builder:
                        p = " " * (len(job[k + 1]) - len(job[k + 1].lstrip()))
                        out += checkout_steps(len(p))[:4] + [""] + release_tag_step(p)
                    if has_builder and "prepare-source.sh" in l:
                        p = " " * (len(l) - len(l.lstrip()) - 2)
                        out += [""] + release_tag_step(p)[:-1]
                    k += 1
                i = j
                continue
        i += 1
    return out, n


def transform(text, name, ref):
    lines = text.splitlines()
    # triggers: replace the top-level `on:` block
    out, i = [], 0
    while i < len(lines):
        if lines[i].startswith("on:"):
            out += TRIGGERS.rstrip("\n").splitlines()
            i += 1
            while i < len(lines) and (not lines[i] or lines[i][0] in " #"):
                i += 1
            out.append("")
            continue
        out.append(lines[i])
        i += 1
    lines, out, i = out, [], 0
    # checkout steps
    n_checkout = 0
    while i < len(lines):
        m = re.match(r"^(\s*)- ", lines[i])
        if m:
            ind = len(m.group(1))
            j = i + 1
            while j < len(lines) and (not lines[j].strip() or len(lines[j]) - len(lines[j].lstrip()) > ind):
                j += 1
            block = lines[i:j]
            while block and not block[-1].strip():   # keep trailing blank lines outside the block
                block.pop()
            if any(re.match(r"^\s*(- )?uses: actions/checkout@", l) for l in block):
                out += checkout_steps(ind)
                out += lines[i + len(block):j]
                n_checkout += 1
                i = j
                continue
        out.append(lines[i])
        i += 1
    out, n_rel = releases(out)
    if n_rel == 0:
        sys.exit(f"{name}: no tag-gated release job found; upstream changed shape, update this script")
    text = "\n".join(out) + "\n"
    # versions: upstream's git describe plus this repository's commit
    text, n_ver = re.subn(r"git describe --tags --always",
                          'echo "$(git describe --tags --always)+g$(echo $GITHUB_SHA | cut -c1-7)"', text)
    if n_checkout == 0 or n_ver == 0:
        sys.exit(f"{name}: expected checkout steps and git describe calls (found {n_checkout}, {n_ver}); "
                 "upstream changed shape, update this script")
    head = (f"# GENERATED by support/sync-workflows.py from upstream FastFlowLM .github/workflows/{name}\n"
            f"# at {ref}. Do not edit; re-run the script after changing FLM_REF.\n")
    return head + text


def main():
    tree = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "src"
    env = dict(l.split("=", 1) for l in (ROOT / "support/upstream.env").read_text().splitlines()
               if l and not l.startswith("#"))
    ref = env["FLM_REF"]
    (ROOT / ".github/workflows").mkdir(parents=True, exist_ok=True)
    hashes = []
    for name in UPSTREAM:
        src = (tree / ".github/workflows" / name).read_bytes()
        hashes.append(f"{hashlib.sha256(src).hexdigest()}  .github/workflows/{name}")
        (ROOT / ".github/workflows" / name).write_text(transform(src.decode(), name, ref))
        print("wrote", ".github/workflows/" + name)
    (ROOT / "support/upstream-workflows.sha256").write_text(
        "# upstream workflow files the generated ones were made from (paths in the upstream tree)\n"
        + "\n".join(hashes) + "\n")


if __name__ == "__main__":
    main()
