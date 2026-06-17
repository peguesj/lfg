#!/usr/bin/env python3
"""
corruption_detector.py — sketch (NOT YET IMPLEMENTED)

Pattern-match live `hdiutil info` + `fsck_apfs -nl` output against the
incident corpus at devdrive/corpus/incidents.ndjson and return:

    (failure_class: str, confidence: float, suggested_action: str)

The intent is for LFG's devdrive reconcile loop to call this BEFORE
attempting destructive recovery, so that:
  - debounce-able transients (errno 5 at session start that does not
    reproduce — see 900HOOKS 2026-06-09) get an `observe-only` action
    with a follow-up probe, instead of a `rebuild` action;
  - reproducible signatures (extent-ref-btree-zeroed on 903CLAUD
    2026-06-09) get `quarantine-and-rebuild` with the corpus-derived
    "known recoverability: none" annotation;
  - schema-only drifts (920COWORK fleet.json host/image mismatch) get
    `lint-only`, never escalating to volume actions.

See docs/lessons/devdrive-corruption-telemetry.md for the failure-class
catalog, telemetry contract, and proposed wiring sites in
lib/devdrive.sh and lib/stfu.sh.
"""

from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

CORPUS_DEFAULT = Path(__file__).parent / "corpus" / "incidents.ndjson"


@dataclass(frozen=True)
class DetectorResult:
    failure_class: str
    confidence: float  # 0.0..1.0
    suggested_action: str  # "observe", "rebuild", "lint", "salvage-attempt", "no-op"
    matched_incidents: tuple[str, ...]
    evidence: dict


def load_corpus(path: Path = CORPUS_DEFAULT) -> list[dict]:
    """Load incidents.ndjson. One JSON record per line. Comments (#) skipped."""
    records: list[dict] = []
    if not path.exists():
        return records
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        records.append(json.loads(line))
    return records


def probe_volume(image_path: str) -> dict:
    """Collect live signals for a volume. Stub — see TODOs.

    Returns dict matching the diagnostic_signals schema in incidents.ndjson:
      hdiutil_attach_error, fsck_apfs_first_failing_check,
      fsck_apfs_node_oid, fsck_apfs_block, info_plist_vs_bckup_diff,
      band_count, band_mtime_range
    """
    # TODO: run `hdiutil info -plist` and `hdiutil attach -nomount <image>`;
    #       parse exit codes + stderr for "Error 112" / "Resource busy" /
    #       "no mountable file systems".
    # TODO: if attached, run `fsck_apfs -nl /dev/diskNs1` and capture the
    #       first "error:" line + its (oid …) annotation.
    # TODO: stat Info.plist vs Info.bckup, diff bytes.
    # TODO: enumerate bands/ subdir for count + mtime min/max.
    return {}


def classify(signals: dict, corpus: list[dict]) -> DetectorResult:
    """Match live signals against corpus. Stub — see TODOs.

    Heuristic order (proposed):
      1. Exact oid match in fsck_apfs_node_oid → high confidence (>=0.9).
      2. Same first_failing_check + same band_count-bucket → medium (0.6).
      3. Same hdiutil_attach_error string → low (0.3) — debounce required.
      4. No match → ("unknown", 0.0, "observe").
    """
    # TODO: actual scoring; for now everything is unknown.
    return DetectorResult(
        failure_class="unknown",
        confidence=0.0,
        suggested_action="observe",
        matched_incidents=(),
        evidence=signals,
    )


def detect(image_path: str, corpus_path: Path = CORPUS_DEFAULT) -> DetectorResult:
    corpus = load_corpus(corpus_path)
    signals = probe_volume(image_path)
    return classify(signals, corpus)


if __name__ == "__main__":
    print("corruption_detector.py — stub")
    print("See docs/lessons/devdrive-corruption-telemetry.md")
    if len(sys.argv) > 1 and sys.argv[1] == "--corpus-count":
        print(f"corpus records: {len(load_corpus())}")
    sys.exit(0)
