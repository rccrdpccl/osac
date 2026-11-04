#!/usr/bin/env python3
"""Filter, merge, and summarize Go coverage profiles for the CaaS scope.

Go cover profiles are lines of:
    <import-path/file>:<startLine>.<startCol>,<endLine>.<endCol> <numStmts> <count>

This tool merges any number of profiles (summing counts for identical
blocks), keeps only blocks whose file matches the CaaS scope patterns
defined below, and prints a per-file / per-section statement-coverage
summary. It also writes the filtered merged profile for `go tool cover
-html`.

Usage:
    python3 tools/caas-coverage/filter_profile.py \
        --profile raw1.out [raw2.out ...] \
        --output filtered.out \
        [--json summary.json]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# CaaS scope (OSAC-6117 "core + worker path"). Patterns match profile file
# paths, which are Go import paths. Keep in sync with SCOPE.md.
# ---------------------------------------------------------------------------

CORE_SECTIONS: dict[str, list[str]] = {
    "fulfillment-service / cluster servers": [
        r"^github\.com/osac-project/osac/fulfillment-service/internal/servers/"
        r"(clusters_server|private_clusters_server|"
        r"cluster_catalog_items_server|private_cluster_catalog_items_server|"
        r"cluster_catalog_item_policies|"
        r"cluster_templates_server|private_cluster_templates_server|"
        r"cluster_versions_server|private_cluster_versions_server|"
        r"cluster_version_resolution)\.go$"
    ],
    "osac-operator / ClusterOrder controllers": [
        r"^github\.com/osac-project/osac/osac-operator/internal/controller/"
        r"(clusterorder_.*|feedback_controller|feedback_sanitize)\.go$"
    ],
    "osac-operator / baremetalworker (CaaS workers)": [
        r"^github\.com/osac-project/osac/osac-operator/internal/controller/baremetalworker/.*\.go$"
    ],
    "osac-metering / cluster events": [r"^github\.com/osac-project/osac-metering/internal/events/cluster\.go$"],
}

# Worker-path dependency, reported separately: the CaaS chain runs through the
# BMF operator, but its tests are BMaaS-owned and are NOT caas-labelled.
WORKER_SECTIONS: dict[str, list[str]] = {
    "bare-metal-fulfillment-operator (worker-path dependency)": [
        r"^github\.com/osac-project/osac/bare-metal-fulfillment-operator/.*\.go$"
    ]
}

LINE_RE = re.compile(r"^(.+?):(\d+\.\d+,\d+\.\d+)\s+(\d+)\s+(\d+)$")


@dataclass
class Block:
    file: str
    span: str
    num_stmts: int
    count: int


@dataclass
class Section:
    patterns: list[re.Pattern[str]]
    files: dict[str, list[Block]] = field(default_factory=dict)

    def matches(self, file: str) -> bool:
        return any(p.match(file) for p in self.patterns)


def parse_profile(path: Path) -> list[Block]:
    blocks: list[Block] = []
    with path.open() as f:
        mode = f.readline()  # "mode: atomic" / "mode: set" — kept, not parsed
        if not mode.startswith("mode:"):
            raise ValueError(f"{path}: missing mode header")
        for line in f:
            line = line.strip()
            if not line:
                continue
            m = LINE_RE.match(line)
            if not m:
                raise ValueError(f"{path}: unparseable line: {line!r}")
            blocks.append(Block(m.group(1), m.group(2), int(m.group(3)), int(m.group(4))))
    return blocks


def merge(blocks: list[Block]) -> dict[tuple[str, str], Block]:
    merged: dict[tuple[str, str], Block] = {}
    for b in blocks:
        key = (b.file, b.span)
        if key in merged:
            merged[key].count += b.count
        else:
            merged[key] = Block(b.file, b.span, b.num_stmts, b.count)
    return merged


def file_pct(blocks: list[Block]) -> tuple[int, int, float]:
    total = sum(b.num_stmts for b in blocks)
    covered = sum(b.num_stmts for b in blocks if b.count > 0)
    pct = 100.0 * covered / total if total else 0.0
    return covered, total, pct


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", nargs="+", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--json", type=Path)
    args = ap.parse_args()

    all_blocks: list[Block] = []
    for p in args.profile:
        all_blocks.extend(parse_profile(p))
    merged = merge(all_blocks)

    sections = {
        name: Section([re.compile(p) for p in pats]) for name, pats in {**CORE_SECTIONS, **WORKER_SECTIONS}.items()
    }

    kept: dict[tuple[str, str], Block] = {}
    for (file, span), b in merged.items():
        for section in sections.values():
            if section.matches(file):
                section.files.setdefault(file, []).append(b)
                kept[(file, span)] = b
                break

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as f:
        f.write("mode: atomic\n")
        for b in sorted(kept.values(), key=lambda b: (b.file, b.span)):
            f.write(f"{b.file}:{b.span} {b.num_stmts} {b.count}\n")

    summary: dict[str, object] = {"sections": {}}
    core_cov = core_tot = worker_cov = worker_tot = 0
    print(
        f"# CaaS coverage from {len(args.profile)} profile(s), "
        f"{len(all_blocks)} raw blocks, {len(kept)} in-scope blocks\n"
    )
    for name, section in sections.items():
        sec_cov = sec_tot = 0
        sec_files: dict[str, object] = {}
        print(f"## {name}")
        for file in sorted(section.files):
            cov, tot, pct = file_pct(section.files[file])
            sec_cov += cov
            sec_tot += tot
            mark = "*" if name in WORKER_SECTIONS else ""
            print(f"  {pct:6.1f}%  {cov:5d}/{tot:<5d}  {file}{mark}")
            sec_files[file] = {"covered": cov, "total": tot, "pct": round(pct, 1)}
        sec_pct = 100.0 * sec_cov / sec_tot if sec_tot else 0.0
        print(f"  ----\n  {sec_pct:6.1f}%  {sec_cov}/{sec_tot} statements (section)\n")
        summary["sections"][name] = {  # type: ignore[index]
            "covered": sec_cov,
            "total": sec_tot,
            "pct": round(sec_pct, 1),
            "files": sec_files,
        }
        if name in WORKER_SECTIONS:
            worker_cov += sec_cov
            worker_tot += sec_tot
        else:
            core_cov += sec_cov
            core_tot += sec_tot

    core_pct = 100.0 * core_cov / core_tot if core_tot else 0.0
    worker_pct = 100.0 * worker_cov / worker_tot if worker_tot else 0.0
    print(f"## CaaS core total: {core_pct:.1f}% ({core_cov}/{core_tot} statements)")
    print(f"## Worker-path dependency total: {worker_pct:.1f}% ({worker_cov}/{worker_tot} statements)")
    summary["core"] = {"covered": core_cov, "total": core_tot, "pct": round(core_pct, 1)}
    summary["worker_path"] = {"covered": worker_cov, "total": worker_tot, "pct": round(worker_pct, 1)}

    if args.json:
        args.json.write_text(json.dumps(summary, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
