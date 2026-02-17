#!/usr/bin/env python3
"""STFU Core - Source Tree Forensics & Unification Engine.

Comprehensive code forensics: dependency analysis, file fingerprinting,
code pattern detection, shared library identification, environment
consolidation, and AI semantic analysis.
"""

import hashlib
import json
import os
import re
import time
from collections import defaultdict
from dataclasses import dataclass, field, asdict
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any, Optional

# ─── Configuration ────────────────────────────────────────────────────────────

SKIP_DIRS = {
    "node_modules", ".git", "dist", "_build", "target", "__pycache__",
    "venv", ".venv", ".next", ".turbo", ".cache", ".parcel-cache",
    ".nuxt", ".output", "deps", "vendor", "Pods", ".gradle",
    ".cargo", "__pypackages__", ".build", ".swiftpm", "build",
    "coverage", ".nyc_output", ".pytest_cache", ".mypy_cache",
}

TEMPLATE_MARKERS = {
    "vite_react_shadcn_ts": "Lovable/v0 React+Vite+Shadcn template",
    "next-supabase-saas-kit-turbo-lite": "MakerKit Next.js SAAS template",
    "next-saas-starter": "Next.js SAAS starter",
    "create-next-app": "Create Next App default",
    "create-react-app": "Create React App default",
    "my-app": "Generic scaffold",
}

MIDDLEWARE_GLOBS = [
    "middleware.ts", "middleware.js", "src/middleware.ts", "src/middleware.js",
    "middleware.py", "app/middleware.py",
    "lib/**/plug*.ex", "lib/**/pipeline*.ex",
    "src/middleware/*.ts", "src/middleware/*.js",
    "app/middleware/*.ts", "app/middleware/*.js",
]

HANDLER_GLOBS = [
    "src/routes/*.ts", "src/routes/*.js", "routes/*.ts", "routes/*.js",
    "lib/**/*_controller.ex", "lib/**/router.ex",
    "src/api/*.ts", "src/api/*.js",
    "app/api/route.ts", "app/api/route.js",
    "app/api/*/route.ts", "app/api/*/route.js",
    "**/views.py", "**/urls.py",
]


# ─── Data Classes ─────────────────────────────────────────────────────────────

@dataclass
class Dependency:
    name: str
    version: str = ""
    category: str = "prod"  # prod | dev
    ecosystem: str = "npm"  # npm | hex | pip | cargo | go


@dataclass
class ProjectManifest:
    name: str
    path: str
    stacks: list = field(default_factory=list)
    deps: list = field(default_factory=list)
    dev_deps: list = field(default_factory=list)
    file_count: int = 0
    template_origin: str = ""
    structural_fingerprint: str = ""
    config_hashes: dict = field(default_factory=dict)

    def all_dep_names(self) -> set:
        return {d.name for d in self.deps} | {d.name for d in self.dev_deps}

    def prod_dep_names(self) -> set:
        return {d.name for d in self.deps}


@dataclass
class OverlapResult:
    project_a: str
    project_b: str
    shared_deps: list = field(default_factory=list)
    unique_to_a: list = field(default_factory=list)
    unique_to_b: list = field(default_factory=list)
    jaccard_similarity: float = 0.0
    structural_similarity: float = 0.0
    code_similarity: float = 0.0
    combined_score: float = 0.0


@dataclass
class CodeDuplicate:
    file_a: str
    file_b: str
    project_a: str
    project_b: str
    similarity: float
    pattern_category: str  # auth | error_handling | cors | validation | custom
    line_count: int = 0


@dataclass
class LibraryCandidate:
    name: str
    lib_type: str  # ui-components | auth | api-client | middleware | testing-config | build-config
    source_projects: list = field(default_factory=list)
    shared_deps: list = field(default_factory=list)
    estimated_dedup_savings_mb: float = 0.0
    effort_hours: int = 0
    priority: int = 3


@dataclass
class EnvironmentGroup:
    projects: list = field(default_factory=list)
    shared_deps: list = field(default_factory=list)
    conflicts: list = field(default_factory=list)
    compatibility_score: float = 0.0
    savings_estimate_mb: float = 0.0
    ecosystem: str = "npm"


# ─── Dependency Analyzer (US-001) ─────────────────────────────────────────────

class DependencyAnalyzer:
    """Extract and cross-reference dependencies across all project types."""

    def extract_npm(self, project_path: Path) -> tuple[list[Dependency], list[Dependency]]:
        """Extract deps from package.json."""
        pkg = project_path / "package.json"
        if not pkg.exists():
            return [], []
        try:
            data = json.loads(pkg.read_text(errors="replace"))
            prod = [Dependency(k, v, "prod", "npm") for k, v in (data.get("dependencies") or {}).items()]
            dev = [Dependency(k, v, "dev", "npm") for k, v in (data.get("devDependencies") or {}).items()]
            return prod, dev
        except (json.JSONDecodeError, KeyError):
            return [], []

    def extract_elixir(self, project_path: Path) -> tuple[list[Dependency], list[Dependency]]:
        """Extract deps from mix.exs."""
        mix = project_path / "mix.exs"
        if not mix.exists():
            return [], []
        try:
            content = mix.read_text(errors="replace")
            deps = re.findall(r'\{:(\w+),\s*"([^"]*)"', content)
            deps += [(m, "") for m in re.findall(r'\{:(\w+),', content) if not any(d[0] == m for d in deps)]
            prod = [Dependency(name, ver, "prod", "hex") for name, ver in deps]
            return prod, []
        except Exception:
            return [], []

    def extract_python(self, project_path: Path) -> tuple[list[Dependency], list[Dependency]]:
        """Extract deps from requirements.txt or pyproject.toml."""
        deps = []
        # requirements.txt
        req = project_path / "requirements.txt"
        if req.exists():
            try:
                for line in req.read_text(errors="replace").splitlines():
                    line = line.strip()
                    if line and not line.startswith("#") and not line.startswith("-"):
                        match = re.match(r"([a-zA-Z0-9_.-]+)", line)
                        if match:
                            ver = re.search(r"[><=!]+(.+)", line)
                            deps.append(Dependency(match.group(1), ver.group(1) if ver else "", "prod", "pip"))
            except Exception:
                pass

        # pyproject.toml
        pyp = project_path / "pyproject.toml"
        if pyp.exists():
            try:
                content = pyp.read_text(errors="replace")
                in_deps = False
                for line in content.splitlines():
                    if "dependencies" in line and "=" in line and "[" in line:
                        in_deps = True
                        continue
                    if in_deps:
                        if line.strip().startswith("]"):
                            in_deps = False
                            continue
                        match = re.match(r'\s*"([a-zA-Z0-9_.-]+)', line)
                        if match:
                            deps.append(Dependency(match.group(1), "", "prod", "pip"))
            except Exception:
                pass

        return deps, []

    def extract_cargo(self, project_path: Path) -> tuple[list[Dependency], list[Dependency]]:
        """Extract deps from Cargo.toml."""
        cargo = project_path / "Cargo.toml"
        if not cargo.exists():
            return [], []
        try:
            content = cargo.read_text(errors="replace")
            deps = re.findall(r'^(\w[\w-]*)\s*=', content, re.MULTILINE)
            prod = [Dependency(d, "", "prod", "cargo") for d in deps if d not in ("name", "version", "edition", "authors", "description")]
            return prod, []
        except Exception:
            return [], []

    def extract_go(self, project_path: Path) -> tuple[list[Dependency], list[Dependency]]:
        """Extract deps from go.mod."""
        gomod = project_path / "go.mod"
        if not gomod.exists():
            return [], []
        try:
            content = gomod.read_text(errors="replace")
            deps = re.findall(r'^\t(\S+)\s+(\S+)', content, re.MULTILINE)
            prod = [Dependency(path.split("/")[-1], ver, "prod", "go") for path, ver in deps]
            return prod, []
        except Exception:
            return [], []

    def analyze(self, target: Path) -> list[ProjectManifest]:
        """Analyze all projects in target directory."""
        manifests = []
        for entry in sorted(target.iterdir()):
            if not entry.is_dir() or entry.name.startswith(".") or entry.is_symlink():
                continue

            m = ProjectManifest(name=entry.name, path=str(entry))

            # Detect stacks
            stack_markers = {
                "package.json": "node", "mix.exs": "elixir", "Cargo.toml": "rust",
                "go.mod": "go", "pyproject.toml": "python", "requirements.txt": "python",
                "Gemfile": "ruby", "Package.swift": "swift", "build.gradle": "java",
            }
            for marker, stack in stack_markers.items():
                if (entry / marker).exists():
                    if stack not in m.stacks:
                        m.stacks.append(stack)

            # Extract deps per ecosystem
            for extractor in [self.extract_npm, self.extract_elixir, self.extract_python, self.extract_cargo, self.extract_go]:
                prod, dev = extractor(entry)
                m.deps.extend(prod)
                m.dev_deps.extend(dev)

            # Template detection
            pkg = entry / "package.json"
            if pkg.exists():
                try:
                    data = json.loads(pkg.read_text(errors="replace"))
                    pkg_name = data.get("name", "")
                    if pkg_name in TEMPLATE_MARKERS:
                        m.template_origin = TEMPLATE_MARKERS[pkg_name]
                except Exception:
                    pass

            manifests.append(m)
        return manifests

    def compute_overlap_matrix(self, manifests: list[ProjectManifest]) -> list[OverlapResult]:
        """Compute pairwise dependency overlap."""
        results = []
        for i, a in enumerate(manifests):
            for j, b in enumerate(manifests):
                if j <= i:
                    continue
                a_deps = a.all_dep_names()
                b_deps = b.all_dep_names()
                if not a_deps and not b_deps:
                    continue
                shared = a_deps & b_deps
                union = a_deps | b_deps
                jaccard = len(shared) / len(union) if union else 0
                if jaccard > 0.05:  # Skip near-zero overlap
                    results.append(OverlapResult(
                        project_a=a.name, project_b=b.name,
                        shared_deps=sorted(shared),
                        unique_to_a=sorted(a_deps - b_deps)[:20],
                        unique_to_b=sorted(b_deps - a_deps)[:20],
                        jaccard_similarity=round(jaccard, 3),
                    ))
        results.sort(key=lambda r: -r.jaccard_similarity)
        return results

    def find_clusters(self, manifests: list[ProjectManifest], threshold: float = 0.6) -> list[list[str]]:
        """Find clusters of 3+ projects sharing >threshold deps."""
        overlaps = self.compute_overlap_matrix(manifests)
        graph = defaultdict(set)
        for o in overlaps:
            if o.jaccard_similarity >= threshold:
                graph[o.project_a].add(o.project_b)
                graph[o.project_b].add(o.project_a)

        visited = set()
        clusters = []
        for node in graph:
            if node in visited:
                continue
            cluster = set()
            queue = [node]
            while queue:
                n = queue.pop()
                if n in visited:
                    continue
                visited.add(n)
                cluster.add(n)
                queue.extend(graph[n] - visited)
            if len(cluster) >= 2:
                clusters.append(sorted(cluster))
        return clusters

    def find_version_conflicts(self, manifests: list[ProjectManifest]) -> list[dict]:
        """Find same dep at different versions across projects."""
        dep_versions = defaultdict(dict)  # {dep_name: {version: [projects]}}
        for m in manifests:
            for d in m.deps + m.dev_deps:
                if d.version:
                    clean_ver = re.sub(r"[\^~>=<]", "", d.version).strip()
                    if clean_ver:
                        dep_versions[d.name].setdefault(clean_ver, []).append(m.name)

        conflicts = []
        for dep, versions in dep_versions.items():
            if len(versions) > 1:
                conflicts.append({
                    "dependency": dep,
                    "versions": {v: ps for v, ps in versions.items()},
                    "project_count": sum(len(ps) for ps in versions.values()),
                })
        conflicts.sort(key=lambda c: -c["project_count"])
        return conflicts[:50]


# ─── File Fingerprinter (US-002) ──────────────────────────────────────────────

class FileFingerprinter:
    """Detect projects built from the same template via structural analysis."""

    def fingerprint(self, project_path: Path) -> tuple[set, dict]:
        """Generate structural fingerprint and config hashes."""
        paths = set()
        try:
            for dirpath, dirnames, filenames in os.walk(project_path):
                # Prune skipped directories in-place (prevents descent)
                dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
                for fname in filenames:
                    rel = os.path.relpath(os.path.join(dirpath, fname), project_path)
                    paths.add(rel)
                if len(paths) > 5000:  # cap per project
                    break
        except (PermissionError, OSError):
            pass

        # Config hashes
        config_hashes = {}
        for cfg in ["tsconfig.json", "tailwind.config.js", "tailwind.config.ts",
                     ".eslintrc.json", ".eslintrc.js", "vite.config.ts", "next.config.js",
                     "next.config.ts", "postcss.config.js"]:
            cfp = project_path / cfg
            if cfp.exists():
                try:
                    content = cfp.read_text(errors="replace")
                    config_hashes[cfg] = hashlib.md5(content.encode()).hexdigest()[:12]
                except Exception:
                    pass

        return paths, config_hashes

    def compute_structural_similarity(self, paths_a: set, paths_b: set) -> float:
        """Jaccard similarity on file path sets."""
        if not paths_a and not paths_b:
            return 0.0
        intersection = paths_a & paths_b
        union = paths_a | paths_b
        return round(len(intersection) / len(union), 3) if union else 0.0

    def analyze(self, manifests: list[ProjectManifest]) -> dict:
        """Run fingerprint analysis on all projects."""
        fingerprints = {}
        for m in manifests:
            paths, hashes = self.fingerprint(Path(m.path))
            m.file_count = len(paths)
            m.config_hashes = hashes
            m.structural_fingerprint = hashlib.md5(
                "\n".join(sorted(paths)).encode()
            ).hexdigest()[:16]
            fingerprints[m.name] = paths

        # Template groups
        template_groups = defaultdict(list)
        for m in manifests:
            if m.template_origin:
                template_groups[m.template_origin].append(m.name)

        # Config similarity groups
        config_groups = defaultdict(list)
        for m in manifests:
            if m.config_hashes:
                key = "|".join(f"{k}={v}" for k, v in sorted(m.config_hashes.items()))
                config_groups[key].append(m.name)

        # Structural similarity pairs (only for projects with overlapping stacks)
        structural_pairs = []
        names = list(fingerprints.keys())
        for i in range(len(names)):
            for j in range(i + 1, len(names)):
                fp_a, fp_b = fingerprints[names[i]], fingerprints[names[j]]
                if len(fp_a) < 5 or len(fp_b) < 5:
                    continue
                sim = self.compute_structural_similarity(fp_a, fp_b)
                if sim > 0.15:
                    structural_pairs.append({
                        "a": names[i], "b": names[j],
                        "structural_similarity": sim,
                        "shared_files": len(fp_a & fp_b),
                    })
        structural_pairs.sort(key=lambda x: -x["structural_similarity"])

        return {
            "template_groups": {k: v for k, v in template_groups.items() if len(v) > 1},
            "config_similarity_groups": [v for v in config_groups.values() if len(v) > 1],
            "structural_pairs": structural_pairs[:30],
        }


# ─── Code Pattern Detector (US-003) ──────────────────────────────────────────

class CodePatternDetector:
    """Detect duplicate middleware, handlers, and utility code across projects."""

    def _find_files(self, project_path: Path, patterns: list[str]) -> list[Path]:
        """Find files matching glob patterns."""
        found = []
        for pattern in patterns:
            try:
                found.extend(project_path.glob(pattern))
            except (OSError, ValueError):
                pass
        return [f for f in found if f.is_file() and f.stat().st_size < 100_000]

    def _normalize_source(self, content: str) -> str:
        """Strip comments, normalize whitespace for comparison."""
        # Remove single-line comments
        content = re.sub(r"//.*$", "", content, flags=re.MULTILINE)
        # Remove multi-line comments
        content = re.sub(r"/\*.*?\*/", "", content, flags=re.DOTALL)
        # Remove Python comments
        content = re.sub(r"#.*$", "", content, flags=re.MULTILINE)
        # Normalize whitespace
        content = re.sub(r"\s+", " ", content).strip()
        return content

    def _shingle_set(self, text: str, k: int = 5) -> set:
        """Create k-shingle set for fast Jaccard comparison."""
        words = text.split()
        if len(words) < k:
            return {text}
        return {" ".join(words[i:i+k]) for i in range(len(words) - k + 1)}

    def _categorize_pattern(self, filepath: str, content: str) -> str:
        """Categorize what type of code pattern this is."""
        lower = filepath.lower() + " " + content[:500].lower()
        if "auth" in lower or "session" in lower or "token" in lower or "login" in lower:
            return "auth"
        if "error" in lower or "exception" in lower or "catch" in lower:
            return "error_handling"
        if "cors" in lower or "origin" in lower:
            return "cors"
        if "valid" in lower or "schema" in lower or "zod" in lower:
            return "validation"
        return "custom"

    def analyze(self, manifests: list[ProjectManifest]) -> list[CodeDuplicate]:
        """Find duplicate code patterns across all projects."""
        # Collect middleware and handler files
        all_files = []  # [(project_name, filepath, normalized_content)]
        for m in manifests:
            p = Path(m.path)
            for f in self._find_files(p, MIDDLEWARE_GLOBS + HANDLER_GLOBS):
                try:
                    raw = f.read_text(errors="replace")
                    norm = self._normalize_source(raw)
                    if len(norm) > 50:  # Skip trivially small files
                        all_files.append((m.name, str(f), norm, len(raw.splitlines())))
                except Exception:
                    pass

        # Cap files to prevent combinatorial explosion
        # Sort by line count desc to prioritize substantial files
        all_files.sort(key=lambda x: -x[3])
        all_files = all_files[:80]

        # Group by hash for exact duplicates, then use length-based pre-filter
        hash_groups = defaultdict(list)
        for idx, (name, path, norm, lines) in enumerate(all_files):
            h = hashlib.md5(norm.encode()).hexdigest()[:16]
            hash_groups[h].append(idx)

        duplicates = []
        seen_pairs = set()

        # Phase 1: Exact duplicates (same hash)
        for h, indices in hash_groups.items():
            if len(indices) < 2:
                continue
            for ii in range(len(indices)):
                for jj in range(ii + 1, len(indices)):
                    i, j = indices[ii], indices[jj]
                    name_a, path_a, norm_a, lines_a = all_files[i]
                    name_b, path_b, norm_b, lines_b = all_files[j]
                    if name_a == name_b:
                        continue
                    pair_key = (min(name_a, name_b), max(name_a, name_b), os.path.basename(path_a))
                    if pair_key in seen_pairs:
                        continue
                    seen_pairs.add(pair_key)
                    cat = self._categorize_pattern(path_a, norm_a)
                    duplicates.append(CodeDuplicate(
                        file_a=path_a, file_b=path_b,
                        project_a=name_a, project_b=name_b,
                        similarity=1.0,
                        pattern_category=cat,
                        line_count=max(lines_a, lines_b),
                    ))

        # Phase 2: Near-duplicates using shingle-based Jaccard (O(n) per file)
        shingles = [self._shingle_set(norm) for _, _, norm, _ in all_files]
        for i in range(len(all_files)):
            for j in range(i + 1, len(all_files)):
                name_a, path_a, norm_a, lines_a = all_files[i]
                name_b, path_b, norm_b, lines_b = all_files[j]
                if name_a == name_b:
                    continue
                sa, sb = shingles[i], shingles[j]
                if not sa or not sb:
                    continue
                intersection = len(sa & sb)
                union = len(sa | sb)
                sim = intersection / union if union else 0
                if sim > 0.3:
                    cat = self._categorize_pattern(path_a, norm_a)
                    duplicates.append(CodeDuplicate(
                        file_a=path_a, file_b=path_b,
                        project_a=name_a, project_b=name_b,
                        similarity=round(sim, 3),
                        pattern_category=cat,
                        line_count=max(lines_a, lines_b),
                    ))
        duplicates.sort(key=lambda d: -d.similarity)
        return duplicates[:50]


# ─── Shared Library Candidate ID (US-004) ─────────────────────────────────────

class LibraryCandidateIdentifier:
    """Recommend shared libraries based on duplication patterns."""

    def analyze(self, manifests: list[ProjectManifest], overlaps: list[OverlapResult],
                duplicates: list[CodeDuplicate]) -> list[LibraryCandidate]:
        candidates = []

        # UI component library: projects sharing >10 @radix-ui deps
        radix_projects = []
        for m in manifests:
            radix_count = sum(1 for d in m.deps if d.name.startswith("@radix-ui/"))
            if radix_count >= 5:
                radix_projects.append(m.name)
        if len(radix_projects) >= 2:
            candidates.append(LibraryCandidate(
                name="@jeremiah/ui-core",
                lib_type="ui-components",
                source_projects=radix_projects,
                shared_deps=[d.name for d in manifests[0].deps if d.name.startswith("@radix-ui/")][:15],
                estimated_dedup_savings_mb=round(len(radix_projects) * 50, 1),
                effort_hours=24,
                priority=1,
            ))

        # Auth library: projects with auth middleware duplicates
        auth_dupes = [d for d in duplicates if d.pattern_category == "auth"]
        if auth_dupes:
            auth_projects = list({d.project_a for d in auth_dupes} | {d.project_b for d in auth_dupes})
            candidates.append(LibraryCandidate(
                name="@jeremiah/auth-core",
                lib_type="auth",
                source_projects=auth_projects,
                shared_deps=["next-auth", "@supabase/supabase-js", "jsonwebtoken"],
                estimated_dedup_savings_mb=round(len(auth_projects) * 5, 1),
                effort_hours=16,
                priority=2,
            ))

        # Testing config: projects sharing vitest/playwright/eslint
        test_projects = []
        for m in manifests:
            test_deps = {d.name for d in m.dev_deps} & {"vitest", "@vitest/ui", "playwright", "@playwright/test", "eslint"}
            if len(test_deps) >= 2:
                test_projects.append(m.name)
        if len(test_projects) >= 3:
            candidates.append(LibraryCandidate(
                name="@jeremiah/test-config",
                lib_type="testing-config",
                source_projects=test_projects,
                shared_deps=["vitest", "playwright", "eslint", "@typescript-eslint/parser"],
                estimated_dedup_savings_mb=round(len(test_projects) * 15, 1),
                effort_hours=8,
                priority=3,
            ))

        # Build config: projects sharing tailwind + vite configs
        tailwind_projects = [m.name for m in manifests if "tailwind.config.js" in m.config_hashes or "tailwind.config.ts" in m.config_hashes]
        if len(tailwind_projects) >= 3:
            candidates.append(LibraryCandidate(
                name="@jeremiah/build-config",
                lib_type="build-config",
                source_projects=tailwind_projects,
                shared_deps=["tailwindcss", "postcss", "autoprefixer"],
                estimated_dedup_savings_mb=round(len(tailwind_projects) * 10, 1),
                effort_hours=8,
                priority=4,
            ))

        # API client: projects sharing axios/fetch patterns + supabase
        api_projects = [m.name for m in manifests if any(d.name in ("axios", "@supabase/supabase-js", "ky") for d in m.deps)]
        if len(api_projects) >= 3:
            candidates.append(LibraryCandidate(
                name="@jeremiah/api-client",
                lib_type="api-client",
                source_projects=api_projects,
                shared_deps=["axios", "@supabase/supabase-js", "zod"],
                estimated_dedup_savings_mb=round(len(api_projects) * 8, 1),
                effort_hours=12,
                priority=3,
            ))

        candidates.sort(key=lambda c: c.priority)
        return candidates


# ─── Environment Consolidation (US-005) ───────────────────────────────────────

class EnvironmentAnalyzer:
    """Identify projects that could share environments."""

    def _parse_version_range(self, ver: str) -> str:
        """Extract major.minor from version string."""
        clean = re.sub(r"[\^~>=<\s]", "", ver).strip()
        parts = clean.split(".")
        if len(parts) >= 2:
            return f"{parts[0]}.{parts[1]}"
        return clean

    def analyze(self, manifests: list[ProjectManifest]) -> list[EnvironmentGroup]:
        """Find groups of projects with compatible dependency versions."""
        # Group by ecosystem
        npm_projects = [m for m in manifests if any(d.ecosystem == "npm" for d in m.deps)]
        pip_projects = [m for m in manifests if any(d.ecosystem == "pip" for d in m.deps)]

        groups = []
        # NPM groups: cluster by React version + framework
        react_groups = defaultdict(list)
        for m in npm_projects:
            react_ver = ""
            framework = "other"
            for d in m.deps:
                if d.name == "react":
                    react_ver = self._parse_version_range(d.version)
                if d.name == "next":
                    framework = "next"
                elif d.name == "vite" or any(dd.name == "vite" for dd in m.dev_deps):
                    framework = "vite"
            key = f"{framework}@react{react_ver}"
            react_groups[key].append(m)

        for key, group_manifests in react_groups.items():
            if len(group_manifests) < 2:
                continue

            # Check for version conflicts within group
            dep_versions = defaultdict(set)
            for m in group_manifests:
                for d in m.deps + m.dev_deps:
                    if d.version:
                        dep_versions[d.name].add(self._parse_version_range(d.version))

            conflicts = [{"dep": k, "versions": list(v)} for k, v in dep_versions.items() if len(v) > 1]
            all_deps = set()
            for m in group_manifests:
                all_deps |= m.all_dep_names()

            compat = 1.0 - (len(conflicts) / max(len(all_deps), 1))
            # Estimate savings: ~200MB per node_modules, shared = save (n-1) * 200
            savings = (len(group_manifests) - 1) * 200

            groups.append(EnvironmentGroup(
                projects=[m.name for m in group_manifests],
                shared_deps=sorted(set.intersection(*[m.all_dep_names() for m in group_manifests]) if group_manifests else set()),
                conflicts=conflicts[:20],
                compatibility_score=round(max(compat, 0), 3),
                savings_estimate_mb=savings,
                ecosystem="npm",
            ))

        # Python groups (simpler - just check shared deps)
        if len(pip_projects) >= 2:
            shared = set.intersection(*[m.all_dep_names() for m in pip_projects]) if pip_projects else set()
            groups.append(EnvironmentGroup(
                projects=[m.name for m in pip_projects],
                shared_deps=sorted(shared),
                conflicts=[],
                compatibility_score=0.8,
                savings_estimate_mb=len(pip_projects) * 50,
                ecosystem="pip",
            ))

        groups.sort(key=lambda g: -g.savings_estimate_mb)
        return groups


# ─── AI Semantic Analyzer (US-006) ────────────────────────────────────────────

class SemanticAnalyzer:
    """AI-enhanced project comparison via LiteLLM proxy."""

    CACHE_PATH = os.path.expanduser("~/.cache/lfg/stfu_ai_cache.json")
    CACHE_TTL = 86400  # 24 hours

    def __init__(self):
        self._cache = self._load_cache()

    def _load_cache(self) -> dict:
        try:
            if os.path.exists(self.CACHE_PATH):
                data = json.loads(Path(self.CACHE_PATH).read_text())
                # Expire old entries
                now = time.time()
                return {k: v for k, v in data.items() if now - v.get("_ts", 0) < self.CACHE_TTL}
        except Exception:
            pass
        return {}

    def _save_cache(self):
        try:
            os.makedirs(os.path.dirname(self.CACHE_PATH), exist_ok=True)
            Path(self.CACHE_PATH).write_text(json.dumps(self._cache, indent=2))
        except Exception:
            pass

    def _call_llm(self, prompt: str) -> Optional[str]:
        """Call LiteLLM proxy."""
        import urllib.request
        import urllib.error

        config_path = os.path.expanduser("~/.config/lfg/ai.yaml")
        endpoint = "http://localhost:4000"
        model = "gpt-4o-mini"
        try:
            import yaml
            with open(config_path) as f:
                cfg = yaml.safe_load(f) or {}
            endpoint = cfg.get("endpoint", endpoint)
            model = cfg.get("model", model)
        except Exception:
            pass

        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": "You are a code forensics assistant. Return JSON only."},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0.2,
            "max_tokens": 512,
        }
        try:
            req = urllib.request.Request(
                f"{endpoint.rstrip('/')}/chat/completions",
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read())
                return data["choices"][0]["message"]["content"]
        except Exception:
            return None

    def analyze_project(self, manifest: ProjectManifest) -> Optional[dict]:
        """AI-analyze a single project's purpose."""
        cache_key = f"project:{manifest.name}"
        if cache_key in self._cache:
            return self._cache[cache_key]

        # Read README snippet
        readme = ""
        for rn in ["README.md", "README", "readme.md"]:
            rp = Path(manifest.path) / rn
            if rp.exists():
                readme = rp.read_text(errors="replace")[:400]
                break

        prompt = f"""Analyze this project. Return JSON: {{"purpose":"one-line","category":"web-app|cli-tool|library|api|mobile|devtool|data|other","merge_risk":"low|medium|high"}}

Name: {manifest.name}
Stack: {', '.join(manifest.stacks)}
Deps ({len(manifest.deps)}): {', '.join(d.name for d in manifest.deps[:15])}
Template: {manifest.template_origin or 'custom'}
README: {readme[:300]}"""

        result = self._call_llm(prompt)
        if result:
            try:
                clean = result.strip()
                if clean.startswith("```"):
                    clean = clean.split("\n", 1)[1].rsplit("```", 1)[0]
                parsed = json.loads(clean)
                parsed["_ts"] = time.time()
                parsed["ai"] = True
                self._cache[cache_key] = parsed
                self._save_cache()
                return parsed
            except Exception:
                pass
        return None

    def batch_analyze(self, manifests: list[ProjectManifest], limit: int = 15) -> dict:
        """Batch analyze top projects."""
        results = {}
        for m in manifests[:limit]:
            r = self.analyze_project(m)
            if r:
                results[m.name] = r
        return results


# ─── Master Orchestrator ──────────────────────────────────────────────────────

class STFUEngine:
    """Orchestrates all STFU analysis modules."""

    def __init__(self, target: str = ""):
        self.target = Path(target or os.path.expanduser("~/Developer"))
        self.dep_analyzer = DependencyAnalyzer()
        self.fingerprinter = FileFingerprinter()
        self.pattern_detector = CodePatternDetector()
        self.library_identifier = LibraryCandidateIdentifier()
        self.env_analyzer = EnvironmentAnalyzer()
        self.semantic_analyzer = SemanticAnalyzer()

    def run_full(self, ai: bool = True) -> dict:
        """Run complete STFU analysis."""
        # Phase 1: Dependency extraction
        manifests = self.dep_analyzer.analyze(self.target)

        # Phase 2: Overlap matrix
        overlaps = self.dep_analyzer.compute_overlap_matrix(manifests)

        # Phase 3: Clusters
        clusters = self.dep_analyzer.find_clusters(manifests)

        # Phase 4: Version conflicts
        conflicts = self.dep_analyzer.find_version_conflicts(manifests)

        # Phase 5: File fingerprinting
        fingerprint_data = self.fingerprinter.analyze(manifests)

        # Phase 6: Code pattern detection
        code_duplicates = self.pattern_detector.analyze(manifests)

        # Phase 7: Library candidates
        library_candidates = self.library_identifier.analyze(manifests, overlaps, code_duplicates)

        # Phase 8: Environment consolidation
        env_groups = self.env_analyzer.analyze(manifests)

        # Phase 9: AI semantic analysis (optional)
        ai_analysis = {}
        if ai:
            ai_analysis = self.semantic_analyzer.batch_analyze(manifests)

        # Duplicates: score > 0.7
        duplicates = [o for o in overlaps if o.jaccard_similarity > 0.7]

        # Compute combined scores
        for o in overlaps:
            # Find structural similarity if computed
            for sp in fingerprint_data.get("structural_pairs", []):
                if (sp["a"] == o.project_a and sp["b"] == o.project_b) or \
                   (sp["a"] == o.project_b and sp["b"] == o.project_a):
                    o.structural_similarity = sp["structural_similarity"]
            # Find code similarity
            for cd in code_duplicates:
                if (cd.project_a == o.project_a and cd.project_b == o.project_b) or \
                   (cd.project_a == o.project_b and cd.project_b == o.project_a):
                    o.code_similarity = max(o.code_similarity, cd.similarity)
            o.combined_score = round(
                o.jaccard_similarity * 0.4 +
                o.structural_similarity * 0.3 +
                o.code_similarity * 0.3, 3
            )

        return {
            "meta": {
                "target": str(self.target),
                "project_count": len(manifests),
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "ai_enabled": ai and bool(ai_analysis),
            },
            "projects": [
                {
                    "name": m.name, "path": m.path, "stacks": m.stacks,
                    "dep_count": len(m.deps), "dev_dep_count": len(m.dev_deps),
                    "file_count": m.file_count,
                    "template_origin": m.template_origin,
                    "ai": ai_analysis.get(m.name, {}),
                }
                for m in manifests
            ],
            "duplicates": [asdict(d) for d in duplicates],
            "relationships": [asdict(o) for o in overlaps[:30]],
            "clusters": clusters,
            "version_conflicts": conflicts[:30],
            "fingerprints": fingerprint_data,
            "code_duplicates": [asdict(cd) for cd in code_duplicates],
            "library_candidates": [asdict(lc) for lc in library_candidates],
            "environment_groups": [asdict(eg) for eg in env_groups],
            "ai_analysis": ai_analysis,
            "summary": {
                "total_projects": len(manifests),
                "duplicate_pairs": len(duplicates),
                "relationship_pairs": len(overlaps),
                "cluster_count": len(clusters),
                "code_duplicate_files": len(code_duplicates),
                "library_candidates": len(library_candidates),
                "env_groups": len(env_groups),
                "version_conflicts": len(conflicts),
                "estimated_savings_mb": sum(eg.savings_estimate_mb for eg in env_groups) +
                                        sum(lc.estimated_dedup_savings_mb for lc in library_candidates),
            },
        }

    def run_deps_only(self) -> dict:
        manifests = self.dep_analyzer.analyze(self.target)
        overlaps = self.dep_analyzer.compute_overlap_matrix(manifests)
        return {"projects": len(manifests), "overlaps": [asdict(o) for o in overlaps[:20]]}

    def run_fingerprint_only(self) -> dict:
        manifests = self.dep_analyzer.analyze(self.target)
        return self.fingerprinter.analyze(manifests)

    def run_duplicates_only(self) -> dict:
        manifests = self.dep_analyzer.analyze(self.target)
        dupes = self.pattern_detector.analyze(manifests)
        return {"code_duplicates": [asdict(d) for d in dupes]}

    def run_libraries_only(self) -> dict:
        manifests = self.dep_analyzer.analyze(self.target)
        overlaps = self.dep_analyzer.compute_overlap_matrix(manifests)
        dupes = self.pattern_detector.analyze(manifests)
        candidates = self.library_identifier.analyze(manifests, overlaps, dupes)
        return {"library_candidates": [asdict(c) for c in candidates]}

    def run_envs_only(self) -> dict:
        manifests = self.dep_analyzer.analyze(self.target)
        groups = self.env_analyzer.analyze(manifests)
        return {"environment_groups": [asdict(g) for g in groups]}

    def merge_check(self, project_a: str, project_b: str) -> dict:
        """Full compatibility check between two projects."""
        manifests = self.dep_analyzer.analyze(self.target)
        ma = next((m for m in manifests if m.name == project_a), None)
        mb = next((m for m in manifests if m.name == project_b), None)
        if not ma or not mb:
            return {"error": f"Project not found: {project_a if not ma else project_b}"}

        # Dep overlap
        shared = ma.all_dep_names() & mb.all_dep_names()
        union = ma.all_dep_names() | mb.all_dep_names()
        dep_sim = len(shared) / len(union) if union else 0

        # Structural
        paths_a, _ = self.fingerprinter.fingerprint(Path(ma.path))
        paths_b, _ = self.fingerprinter.fingerprint(Path(mb.path))
        struct_sim = self.fingerprinter.compute_structural_similarity(paths_a, paths_b)

        # Code duplicates between these two
        dupes = [d for d in self.pattern_detector.analyze([ma, mb]) if d.similarity > 0.5]

        # Version conflicts
        conflicts = []
        for d_a in ma.deps + ma.dev_deps:
            for d_b in mb.deps + mb.dev_deps:
                if d_a.name == d_b.name and d_a.version and d_b.version:
                    v_a = re.sub(r"[\^~>=<]", "", d_a.version)
                    v_b = re.sub(r"[\^~>=<]", "", d_b.version)
                    if v_a != v_b:
                        conflicts.append({"dep": d_a.name, "a": v_a, "b": v_b})

        merge_score = round(dep_sim * 0.4 + struct_sim * 0.3 + (0.3 if not conflicts else 0.1), 3)

        return {
            "project_a": project_a,
            "project_b": project_b,
            "dependency_similarity": round(dep_sim, 3),
            "structural_similarity": round(struct_sim, 3),
            "shared_deps": len(shared),
            "unique_to_a": len(ma.all_dep_names() - shared),
            "unique_to_b": len(mb.all_dep_names() - shared),
            "version_conflicts": conflicts[:20],
            "code_duplicates": [asdict(d) for d in dupes],
            "merge_score": merge_score,
            "recommendation": "merge" if merge_score > 0.7 else "review" if merge_score > 0.4 else "keep_separate",
        }


# ─── CLI Entry Point ─────────────────────────────────────────────────────────

if __name__ == "__main__":
    import sys

    cmd = sys.argv[1] if len(sys.argv) > 1 else "full"
    target = ""
    ai = True
    json_compact = False

    # Parse args
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--no-ai":
            ai = False
        elif args[i] == "--json":
            json_compact = True
        elif args[i] == "--target":
            target = args[i + 1]
            i += 1
        elif not args[i].startswith("-"):
            target = args[i]
        i += 1

    engine = STFUEngine(target)

    if cmd == "full":
        data = engine.run_full(ai=ai)
    elif cmd == "deps":
        data = engine.run_deps_only()
    elif cmd == "fingerprint":
        data = engine.run_fingerprint_only()
    elif cmd == "duplicates":
        data = engine.run_duplicates_only()
    elif cmd == "libraries":
        data = engine.run_libraries_only()
    elif cmd == "envs":
        data = engine.run_envs_only()
    elif cmd == "merge-check":
        if len(args) < 2:
            print(json.dumps({"error": "Usage: stfu_core.py merge-check <project_a> <project_b>"}))
            sys.exit(1)
        non_flag_args = [a for a in args if not a.startswith("-")]
        data = engine.merge_check(non_flag_args[0], non_flag_args[1])
    else:
        print(json.dumps({"error": f"Unknown command: {cmd}"}))
        sys.exit(1)

    print(json.dumps(data, indent=None if json_compact else 2))
