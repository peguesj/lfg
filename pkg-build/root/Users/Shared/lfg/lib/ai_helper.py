#!/usr/bin/env python3
"""LFG AI Helper - Multi-backend LLM calls for project analysis.

Backends: litellm (default), claude (Anthropic API), ollama (local).
Configured via ~/.config/lfg/ai.yaml or settings.yaml ai.backend field.
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

CONFIG_PATH = os.path.expanduser("~/.config/lfg/ai.yaml")
SETTINGS_PATH = os.path.expanduser("~/.config/lfg/settings.yaml")

_MAX_RETRIES: int = 3
_BACKOFF_BASE: float = 1.0


# ---------------------------------------------------------------------------
# Custom Exceptions
# ---------------------------------------------------------------------------

class LFGAIError(Exception):
    """Base exception for LFG AI operations."""

class LFGConnectionError(LFGAIError):
    """Raised when the AI backend is unreachable."""

class LFGConfigError(LFGAIError):
    """Raised when AI configuration is missing or invalid."""


def _log_error(msg: str) -> None:
    print(f"[LFG-AI ERROR] {msg}", file=sys.stderr)

def _log_warn(msg: str) -> None:
    print(f"[LFG-AI WARN] {msg}", file=sys.stderr)


def load_config():
    """Load AI config from YAML (fallback to defaults if unavailable)."""
    defaults = {
        "backend": "litellm",
        "model": "gpt-4o-mini",
        "endpoint": "http://localhost:4000",
        "temperature": 0.3,
        "system_override": False,
        "max_tokens": 1024,
    }
    # Load ai.yaml
    try:
        import yaml
        with open(CONFIG_PATH) as f:
            cfg = yaml.safe_load(f) or {}
        defaults.update(cfg)
    except Exception:
        pass
    # Check settings.yaml for ai.backend override
    try:
        if os.path.exists(SETTINGS_PATH):
            in_ai = False
            for line in open(SETTINGS_PATH):
                stripped = line.strip()
                if stripped == "ai:" or stripped.startswith("ai:"):
                    in_ai = True
                    continue
                if in_ai and line.startswith("  "):
                    import re
                    m = re.match(r"\s+(\w+):\s*(.*)", line)
                    if m:
                        key, val = m.group(1), m.group(2).strip().strip("\"'")
                        if val:
                            defaults[key] = val
                elif in_ai and not line.startswith(" "):
                    in_ai = False
    except Exception:
        pass
    return defaults


def call_llm(prompt, system="You are a project analysis assistant. Return JSON only.", config=None):
    """Call LLM with multi-backend support."""
    cfg = config or load_config()
    backend = cfg.get("backend", "litellm")

    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": prompt},
    ]

    if backend == "claude":
        return _call_claude(messages, cfg)
    elif backend == "ollama":
        return _call_ollama(messages, cfg)
    else:
        return _call_openai_compat(messages, cfg)


def _call_openai_compat(messages: list, cfg: dict) -> Optional[str]:
    """OpenAI-compatible endpoint (LiteLLM proxy) with retry/backoff."""
    endpoint = cfg["endpoint"].rstrip("/")
    url = f"{endpoint}/chat/completions"
    payload = {
        "model": cfg["model"],
        "messages": messages,
        "temperature": float(cfg.get("temperature", 0.3)),
        "max_tokens": int(cfg.get("max_tokens", 1024)),
    }
    last_exc: Optional[Exception] = None
    for attempt in range(1, _MAX_RETRIES + 1):
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read())
                return data["choices"][0]["message"]["content"]
        except urllib.error.URLError as exc:
            last_exc = exc
            _log_warn(f"OpenAI-compat attempt {attempt}/{_MAX_RETRIES}: {exc}")
        except (json.JSONDecodeError, KeyError) as exc:
            _log_error(f"Malformed response from {url}: {exc}")
            return None
        except Exception as exc:
            last_exc = exc
            _log_warn(f"Unexpected error attempt {attempt}/{_MAX_RETRIES}: {exc}")
        if attempt < _MAX_RETRIES:
            time.sleep(_BACKOFF_BASE * (2 ** (attempt - 1)))
    _log_error(f"All {_MAX_RETRIES} attempts to {url} failed: {last_exc}")
    return None


def _call_claude(messages: list, cfg: dict) -> Optional[str]:
    """Direct Anthropic API call with retry/backoff."""
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        _log_warn("ANTHROPIC_API_KEY not set")
        return None

    model = cfg["model"]
    if not model.startswith("claude"):
        model = "claude-sonnet-4-5-20250929"

    system_msg = ""
    api_messages = []
    for m in messages:
        if m["role"] == "system":
            system_msg = m["content"]
        else:
            api_messages.append({"role": m["role"], "content": m["content"]})

    payload = {
        "model": model,
        "max_tokens": int(cfg.get("max_tokens", 1024)),
        "messages": api_messages,
    }
    if system_msg:
        payload["system"] = system_msg

    last_exc: Optional[Exception] = None
    for attempt in range(1, _MAX_RETRIES + 1):
        try:
            req = urllib.request.Request(
                "https://api.anthropic.com/v1/messages",
                data=json.dumps(payload).encode(),
                headers={
                    "Content-Type": "application/json",
                    "x-api-key": api_key,
                    "anthropic-version": "2023-06-01",
                },
            )
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.loads(resp.read())
                return data["content"][0]["text"]
        except urllib.error.URLError as exc:
            last_exc = exc
            _log_warn(f"Claude API attempt {attempt}/{_MAX_RETRIES}: {exc}")
        except (json.JSONDecodeError, KeyError) as exc:
            _log_error(f"Malformed Claude response: {exc}")
            return None
        except Exception as exc:
            last_exc = exc
            _log_warn(f"Claude unexpected error attempt {attempt}/{_MAX_RETRIES}: {exc}")
        if attempt < _MAX_RETRIES:
            time.sleep(_BACKOFF_BASE * (2 ** (attempt - 1)))
    _log_error(f"All {_MAX_RETRIES} Claude API attempts failed: {last_exc}")
    return None


def _call_ollama(messages: list, cfg: dict) -> Optional[str]:
    """Ollama local API call with retry/backoff."""
    model = cfg["model"]
    if model.startswith("ollama/"):
        model = model[7:]

    payload = {
        "model": model,
        "messages": messages,
        "stream": False,
    }
    last_exc: Optional[Exception] = None
    for attempt in range(1, _MAX_RETRIES + 1):
        try:
            req = urllib.request.Request(
                "http://localhost:11434/api/chat",
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = json.loads(resp.read())
                return data["message"]["content"]
        except urllib.error.URLError as exc:
            last_exc = exc
            _log_warn(f"Ollama attempt {attempt}/{_MAX_RETRIES}: {exc}")
        except (json.JSONDecodeError, KeyError) as exc:
            _log_error(f"Malformed Ollama response: {exc}")
            return None
        except Exception as exc:
            last_exc = exc
            _log_warn(f"Ollama unexpected error attempt {attempt}/{_MAX_RETRIES}: {exc}")
        if attempt < _MAX_RETRIES:
            time.sleep(_BACKOFF_BASE * (2 ** (attempt - 1)))
    _log_error(f"All {_MAX_RETRIES} Ollama attempts failed: {last_exc}")
    return None


def scan_project(path):
    """Gather lightweight project metadata for analysis."""
    p = Path(path)
    info = {"name": p.name, "path": str(p)}

    # Detect stack from files
    markers = {
        "package.json": "node",
        "mix.exs": "elixir",
        "Cargo.toml": "rust",
        "go.mod": "go",
        "pyproject.toml": "python",
        "requirements.txt": "python",
        "Gemfile": "ruby",
        "Package.swift": "swift",
        "build.gradle": "java",
        "pom.xml": "java",
    }
    info["stack"] = []
    for marker, stack in markers.items():
        if (p / marker).exists():
            info["stack"].append(stack)

    # Read README snippet
    for readme in ["README.md", "README", "readme.md"]:
        rp = p / readme
        if rp.exists():
            info["readme_snippet"] = rp.read_text(errors="replace")[:500]
            break

    # Count files by extension
    ext_counts = {}
    try:
        for f in p.rglob("*"):
            if f.is_file() and not any(part.startswith(".") or part == "node_modules" for part in f.parts):
                ext = f.suffix.lower()
                if ext:
                    ext_counts[ext] = ext_counts.get(ext, 0) + 1
    except PermissionError:
        pass
    info["top_extensions"] = sorted(ext_counts.items(), key=lambda x: -x[1])[:8]

    return info


def cmd_analyze(path):
    """Analyze a single project."""
    info = scan_project(path)
    prompt = f"""Analyze this project and return JSON with these fields:
- purpose: one-line description of what this project does
- category: one of [web-app, cli-tool, library, api, mobile, devtool, data, other]
- stack: detected technology stack
- cleanup_priority: 1-5 (5 = most cleanable space)
- suggestion: one actionable suggestion

Project info:
{json.dumps(info, indent=2)}"""

    result = call_llm(prompt)
    if result:
        # Try to parse JSON from response
        try:
            # Strip markdown code fences if present
            clean = result.strip()
            if clean.startswith("```"):
                clean = clean.split("\n", 1)[1].rsplit("```", 1)[0]
            print(clean)
        except Exception:
            print(json.dumps({"purpose": result[:200], "error": "parse"}))
    else:
        # Fallback: heuristic analysis without AI
        purpose = f"{info['name']} - {', '.join(info['stack']) or 'unknown'} project"
        print(json.dumps({
            "purpose": purpose,
            "category": "other",
            "stack": info["stack"],
            "cleanup_priority": 3,
            "suggestion": "AI unavailable - check endpoint",
            "ai": False,
        }))


def cmd_compare(path_a, path_b):
    """Compare two projects for similarity."""
    info_a = scan_project(path_a)
    info_b = scan_project(path_b)

    prompt = f"""Compare these two projects and return JSON:
- similarity_score: 0.0 to 1.0
- shared_deps: list of shared dependencies/patterns
- relationship: one of [duplicate, fork, related, unrelated]
- merge_candidate: boolean
- explanation: brief explanation

Project A: {json.dumps(info_a, indent=2)}
Project B: {json.dumps(info_b, indent=2)}"""

    result = call_llm(prompt)
    if result:
        try:
            clean = result.strip()
            if clean.startswith("```"):
                clean = clean.split("\n", 1)[1].rsplit("```", 1)[0]
            print(clean)
        except Exception:
            print(json.dumps({"similarity_score": 0, "error": "parse"}))
    else:
        # Heuristic: shared stack overlap
        shared = set(info_a["stack"]) & set(info_b["stack"])
        score = len(shared) / max(len(set(info_a["stack"]) | set(info_b["stack"])), 1)
        print(json.dumps({
            "similarity_score": round(score, 2),
            "shared_deps": list(shared),
            "relationship": "related" if score > 0.5 else "unrelated",
            "merge_candidate": False,
            "explanation": "Heuristic comparison (AI unavailable)",
            "ai": False,
        }))


def cmd_suggest(path):
    """Get cleanup/optimization suggestions for a project."""
    info = scan_project(path)
    prompt = f"""Suggest cleanup actions for this project. Return JSON array of objects:
- action: what to do
- command: shell command to execute
- estimated_savings: estimated disk space savings
- risk: low/medium/high

Project: {json.dumps(info, indent=2)}"""

    result = call_llm(prompt)
    if result:
        try:
            clean = result.strip()
            if clean.startswith("```"):
                clean = clean.split("\n", 1)[1].rsplit("```", 1)[0]
            print(clean)
        except Exception:
            print("[]")
    else:
        print(json.dumps([
            {"action": "Remove node_modules and reinstall", "command": f"rm -rf {path}/node_modules && cd {path} && npm install", "estimated_savings": "500MB+", "risk": "low"},
            {"action": "Clear build cache", "command": f"rm -rf {path}/dist {path}/.next {path}/_build", "estimated_savings": "100MB+", "risk": "low"},
        ]))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: ai_helper.py [analyze|compare|suggest] <args>"}))
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "analyze" and len(sys.argv) >= 3:
        cmd_analyze(sys.argv[2])
    elif cmd == "compare" and len(sys.argv) >= 4:
        cmd_compare(sys.argv[2], sys.argv[3])
    elif cmd == "suggest" and len(sys.argv) >= 3:
        cmd_suggest(sys.argv[2])
    else:
        print(json.dumps({"error": f"Unknown command: {cmd}"}))
        sys.exit(1)
