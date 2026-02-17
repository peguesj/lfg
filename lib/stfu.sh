#!/usr/bin/env bash
# lfg stfu - Source Tree Forensics & Unification
# Scans projects for relationships, duplicates, coalescence candidates
set -uo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-$HOME/Developer}"
JSON_MODE=false
[[ "${1:-}" == "--json" ]] && { JSON_MODE=true; TARGET="${2:-$HOME/Developer}"; }

AI_HELPER="$LFG_DIR/lib/ai_helper.py"

# Scan all projects and gather metadata
python3 << PYEOF
import json, os, sys
from pathlib import Path
from collections import defaultdict

target = "$TARGET"
projects = []

for entry in sorted(Path(target).iterdir()):
    if not entry.is_dir() or entry.name.startswith('.') or entry.is_symlink():
        continue
    info = {"name": entry.name, "path": str(entry), "stack": [], "deps": []}

    # Detect stack
    markers = {
        "package.json": "node", "mix.exs": "elixir", "Cargo.toml": "rust",
        "go.mod": "go", "pyproject.toml": "python", "requirements.txt": "python",
        "Gemfile": "ruby", "Package.swift": "swift",
    }
    for marker, stack in markers.items():
        if (entry / marker).exists():
            info["stack"].append(stack)

    # Extract deps from package.json
    pkg = entry / "package.json"
    if pkg.exists():
        try:
            data = json.loads(pkg.read_text(errors="replace"))
            info["deps"] = list((data.get("dependencies", {}) or {}).keys())[:20]
        except: pass

    # Extract deps from mix.exs
    mix = entry / "mix.exs"
    if mix.exists():
        try:
            content = mix.read_text(errors="replace")
            import re
            info["deps"] += re.findall(r'\{:(\w+),', content)[:20]
        except: pass

    projects.append(info)

# Compute pairwise similarity
relationships = []
for i, a in enumerate(projects):
    for j, b in enumerate(projects):
        if j <= i:
            continue
        # Stack overlap
        stack_shared = set(a["stack"]) & set(b["stack"])
        stack_union = set(a["stack"]) | set(b["stack"])
        stack_score = len(stack_shared) / max(len(stack_union), 1)

        # Dep overlap
        deps_shared = set(a["deps"]) & set(b["deps"])
        deps_union = set(a["deps"]) | set(b["deps"])
        dep_score = len(deps_shared) / max(len(deps_union), 1)

        # Name similarity (simple prefix/suffix)
        name_score = 0
        na, nb = a["name"].lower(), b["name"].lower()
        if na in nb or nb in na:
            name_score = 0.5
        elif na[:4] == nb[:4]:
            name_score = 0.3

        score = round(stack_score * 0.3 + dep_score * 0.5 + name_score * 0.2, 3)
        if score > 0.1:
            relationships.append({
                "a": a["name"], "b": b["name"], "score": score,
                "shared_stack": list(stack_shared),
                "shared_deps": list(deps_shared)[:10],
            })

relationships.sort(key=lambda r: -r["score"])

# Identify clusters (groups with >0.3 similarity)
clusters = defaultdict(set)
for r in relationships:
    if r["score"] > 0.3:
        key = frozenset([r["a"], r["b"]])
        for c_key, c_members in list(clusters.items()):
            if r["a"] in c_members or r["b"] in c_members:
                c_members.add(r["a"])
                c_members.add(r["b"])
                break
        else:
            clusters[frozenset([r["a"], r["b"]])] = {r["a"], r["b"]}

# Merge overlapping clusters
merged = []
for members in clusters.values():
    found = False
    for m in merged:
        if m & members:
            m |= members
            found = True
            break
    if not found:
        merged.append(members)

# Duplicates (score > 0.7)
duplicates = [r for r in relationships if r["score"] > 0.7]

result = {
    "project_count": len(projects),
    "relationships": relationships[:20],
    "duplicates": duplicates[:10],
    "clusters": [sorted(list(m)) for m in merged if len(m) > 1][:10],
}

json_mode = "$JSON_MODE" == "true"
print(json.dumps(result, indent=None if json_mode else 2))
PYEOF
