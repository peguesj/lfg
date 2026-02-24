#!/usr/bin/env python3
"""LFG Chat Server - HTTP daemon with agent routing, conversation state, SSE streaming.

Listens on localhost:3033. Provides:
  POST /chat       - Send message, get SSE-streamed response
  GET  /history    - Conversation history
  POST /search     - Semantic search query
  GET  /agents     - List available agents
  GET  /health     - Health check

Multi-backend: reads ai.backend from settings.yaml (litellm|claude|ollama).
"""

import json
import os
import signal
import sys
import time
import threading
import urllib.request
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from typing import Any, Dict, List, Optional

# Paths
CONFIG_DIR = Path.home() / ".config" / "lfg"
SETTINGS_FILE = CONFIG_DIR / "settings.yaml"
AI_CONFIG_FILE = CONFIG_DIR / "ai.yaml"
STATE_FILE = CONFIG_DIR / "state.json"
LOG_FILE = CONFIG_DIR / "lfg.log"
HISTORY_FILE = CONFIG_DIR / "chat_history.json"
SEARCH_DB = CONFIG_DIR / "search.db"

LFG_DIR = Path(__file__).resolve().parent.parent

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

def _parse_yaml_simple(path):
    """Minimal YAML parser for our flat config files."""
    result = {}
    current_key = None
    if not path.exists():
        return result
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("- ") and current_key:
            if not isinstance(result.get(current_key), list):
                result[current_key] = []
            result[current_key].append(stripped[2:].strip().strip("\"'"))
            continue
        if line.startswith("  ") and not stripped.startswith("-"):
            import re
            m = re.match(r"\s+(\w+):\s*(.*)", line)
            if m and current_key:
                if not isinstance(result.get(current_key), dict):
                    result[current_key] = {}
                result[current_key][m.group(1)] = m.group(2).strip().strip("\"'")
            continue
        import re
        m = re.match(r"^(\w+):\s*(.*)", line)
        if m:
            current_key = m.group(1)
            val = m.group(2).strip().strip("\"'")
            if val:
                result[current_key] = val
    return result


def load_ai_config():
    """Load AI backend configuration."""
    # Check settings.yaml for ai.backend
    settings = _parse_yaml_simple(SETTINGS_FILE)
    ai_settings = settings.get("ai", {})
    if isinstance(ai_settings, str):
        ai_settings = {}

    # Also load ai.yaml for model-specific config
    ai_yaml = _parse_yaml_simple(AI_CONFIG_FILE)

    backend = ai_settings.get("backend", ai_yaml.get("backend", "litellm"))
    model = ai_settings.get("model", ai_yaml.get("model", "gpt-4o-mini"))
    endpoint = ai_settings.get("endpoint", ai_yaml.get("endpoint", "http://localhost:4000"))
    temperature = float(ai_settings.get("temperature", ai_yaml.get("temperature", "0.3")))
    max_tokens = int(ai_settings.get("max_tokens", ai_yaml.get("max_tokens", "1024")))

    return {
        "backend": backend,
        "model": model,
        "endpoint": endpoint.rstrip("/"),
        "temperature": temperature,
        "max_tokens": max_tokens,
    }


# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

def load_state():
    """Load current LFG state."""
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {"modules": {}}


def load_log_tail(n=50):
    """Load last N lines of lfg.log."""
    try:
        lines = LOG_FILE.read_text().splitlines()
        return lines[-n:]
    except Exception:
        return []


# ---------------------------------------------------------------------------
# Agent System
# ---------------------------------------------------------------------------

AGENT_PROMPTS = {
    "router": (
        "You are the LFG assistant. You help users manage their macOS disk space "
        "using the LFG toolkit. Analyze user intent and either answer directly or "
        "hand off to a specialist.\n\n"
        "Available specialists:\n"
        "- WTFS: disk usage analysis, directory scanning, space breakdown\n"
        "- DTF: cache cleanup, temporary file removal, reclaimable space\n"
        "- BTAU: backup management, scheduling, restore, migration\n"
        "- DEVDRIVE: developer drive volumes, symlink forests, sync\n"
        "- STFU: source tree forensics, duplicate detection, project relationships\n\n"
        "DELEGATION RULES:\n"
        "- To delegate, put EXACTLY [DELEGATE:AGENT_NAME] as the very first text of your "
        "response, on its own line, with nothing before it. Example:\n"
        "[DELEGATE:WTFS]\n"
        "- Do NOT include [DELEGATE:...] anywhere else in your response.\n"
        "- Do NOT mention delegation mechanics to the user. Never show [DELEGATE:...] text.\n"
        "- When answering directly, just respond naturally and helpfully.\n"
        "- Be concise, friendly, and technical. Speak like a knowledgeable assistant, not a syslog."
    ),
    "wtfs": (
        "You are the WTFS Agent (Where's The Free Space). You specialize in disk usage "
        "analysis. You know how to interpret du output, identify space hogs, and recommend "
        "which directories to clean or archive.\n\n"
        "Available commands:\n"
        "- lfg wtfs [path] - scan directory for disk usage\n"
        "- lfg wtfs ~/Developer - scan developer directory\n"
    ),
    "dtf": (
        "You are the DTF Agent (Delete Temp Files). You specialize in cache identification "
        "and cleanup strategies. You know common cache locations on macOS and can recommend "
        "safe vs aggressive cleaning approaches.\n\n"
        "Available commands:\n"
        "- lfg dtf - dry run cache scan\n"
        "- lfg dtf --force - execute cache cleanup\n"
        "- lfg dtf --force --docker - include Docker cleanup\n"
        "- lfg dtf --force --sudo - include system caches\n"
    ),
    "btau": (
        "You are the BTAU Agent (Back That App Up). You specialize in backup scheduling, "
        "restore guidance, and migration planning using sparse images.\n\n"
        "Available commands:\n"
        "- lfg btau - view backup status\n"
        "- lfg btau backup - create backup\n"
        "- lfg btau restore - restore from backup\n"
        "- lfg btau discover - discover volumes\n"
        "- lfg btau migrate - migrate project\n"
    ),
    "devdrive": (
        "You are the DEVDRIVE Agent. You specialize in developer drive volume management, "
        "symlink forest maintenance, and sync operations.\n\n"
        "Available commands:\n"
        "- lfg devdrive mount - mount developer drive\n"
        "- lfg devdrive unmount - safely unmount\n"
        "- lfg devdrive sync - sync symlink forest\n"
        "- lfg devdrive verify - verify symlink integrity\n"
    ),
    "stfu": (
        "You are the STFU Agent (Source Tree Forensics & Unification). You specialize in "
        "code forensics, duplicate detection, and project relationship analysis.\n\n"
        "Available commands:\n"
        "- lfg stfu - full analysis (dry run)\n"
        "- lfg stfu deps - dependency analysis\n"
        "- lfg stfu duplicates - duplicate detection\n"
        "- lfg stfu fingerprint - file fingerprinting\n"
        "- lfg stfu libraries - library extraction candidates\n"
    ),
}


def build_agent_system_prompt(agent_name):
    """Build system prompt with live state injection."""
    base = AGENT_PROMPTS.get(agent_name, AGENT_PROMPTS["router"])
    state = load_state()
    log_tail = load_log_tail(20)

    state_summary = json.dumps(state.get("modules", {}), indent=2)
    log_summary = "\n".join(log_tail) if log_tail else "(no recent logs)"

    return (
        f"{base}\n\n"
        f"--- Current LFG State ---\n{state_summary}\n\n"
        f"--- Recent Log ---\n{log_summary}\n"
    )


# ---------------------------------------------------------------------------
# LLM Call (multi-backend)
# ---------------------------------------------------------------------------

def call_llm(messages, config=None, stream=False):
    """Call LLM with multi-backend support. Returns response text."""
    cfg = config or load_ai_config()
    backend = cfg["backend"]

    if backend == "claude":
        return _call_claude(messages, cfg, stream)
    elif backend == "ollama":
        return _call_ollama(messages, cfg, stream)
    else:  # litellm (default)
        return _call_openai_compat(messages, cfg, stream)


def _call_openai_compat(messages, cfg, stream=False):
    """OpenAI-compatible endpoint (LiteLLM proxy)."""
    endpoint = cfg["endpoint"]
    # Try /v1/chat/completions first, fall back to /chat/completions
    urls = [f"{endpoint}/v1/chat/completions", f"{endpoint}/chat/completions"]
    payload = {
        "model": cfg["model"],
        "messages": messages,
        "temperature": cfg["temperature"],
        "max_tokens": cfg["max_tokens"],
        "stream": stream,
    }
    data_bytes = json.dumps(payload).encode()

    last_err = None
    for url in urls:
        req = urllib.request.Request(
            url,
            data=data_bytes,
            headers={"Content-Type": "application/json"},
        )
        try:
            if stream:
                return _stream_openai(req)
            else:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    data = json.loads(resp.read())
                    return data["choices"][0]["message"]["content"]
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code == 404:
                continue  # try next URL variant
            return f"(LLM backend error {e.code}: {e.reason})"
        except urllib.error.URLError as e:
            return f"(Cannot reach LLM backend at {endpoint} -- {e.reason}. Check that your AI backend is running.)"
        except Exception as e:
            last_err = e
            continue

    return f"(LLM backend at {endpoint} returned no valid response: {last_err})"


def _stream_openai(req):
    """Generator yielding SSE chunks from OpenAI-compatible stream."""
    with urllib.request.urlopen(req, timeout=120) as resp:
        for line in resp:
            line = line.decode("utf-8").strip()
            if line.startswith("data: "):
                data = line[6:]
                if data == "[DONE]":
                    return
                try:
                    chunk = json.loads(data)
                    delta = chunk.get("choices", [{}])[0].get("delta", {})
                    content = delta.get("content", "")
                    if content:
                        yield content
                except json.JSONDecodeError:
                    continue


def _call_claude(messages, cfg, stream=False):
    """Direct Anthropic API call."""
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        return "(Error: ANTHROPIC_API_KEY not set)"

    model = cfg["model"]
    if not model.startswith("claude"):
        model = "claude-sonnet-4-5-20250929"

    # Convert messages to Anthropic format
    system_msg = ""
    api_messages = []
    for m in messages:
        if m["role"] == "system":
            system_msg = m["content"]
        else:
            api_messages.append({"role": m["role"], "content": m["content"]})

    payload = {
        "model": model,
        "max_tokens": cfg["max_tokens"],
        "messages": api_messages,
    }
    if system_msg:
        payload["system"] = system_msg

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read())
            return data["content"][0]["text"]
    except Exception as e:
        return f"(Claude API error: {e})"


def _call_ollama(messages, cfg, stream=False):
    """Ollama API call."""
    model = cfg["model"]
    if model.startswith("ollama/"):
        model = model[7:]

    payload = {
        "model": model,
        "messages": messages,
        "stream": False,
    }
    req = urllib.request.Request(
        "http://localhost:11434/api/chat",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read())
            return data["message"]["content"]
    except urllib.error.URLError as e:
        return f"(Ollama not reachable at localhost:11434 -- {e.reason}. Is Ollama running?)"
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:200]
        if "not found" in body.lower():
            return f"(Ollama model '{model}' not found. Pull it with: ollama pull {model})"
        return f"(Ollama error {e.code}: {body})"
    except Exception as e:
        return f"(Ollama error: {e})"


# ---------------------------------------------------------------------------
# Conversation Manager
# ---------------------------------------------------------------------------

class ConversationManager:
    def __init__(self):
        self.conversations = {}  # id -> [messages]
        self.lock = threading.Lock()
        self._load()

    def _load(self):
        try:
            data = json.loads(HISTORY_FILE.read_text())
            self.conversations = data.get("conversations", {})
            # Prune to last 50
            if len(self.conversations) > 50:
                keys = sorted(self.conversations.keys())
                for k in keys[:-50]:
                    del self.conversations[k]
        except Exception:
            self.conversations = {}

    def _save(self):
        HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
        HISTORY_FILE.write_text(json.dumps({
            "conversations": self.conversations,
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }, indent=2))

    def get_or_create(self, conv_id=None):
        with self.lock:
            if conv_id and conv_id in self.conversations:
                return conv_id, self.conversations[conv_id]
            new_id = conv_id or f"conv_{int(time.time())}"
            self.conversations[new_id] = []
            return new_id, self.conversations[new_id]

    def add_message(self, conv_id, role, content, agent=None):
        with self.lock:
            if conv_id not in self.conversations:
                self.conversations[conv_id] = []
            msg = {"role": role, "content": content, "timestamp": time.time()}
            if agent:
                msg["agent"] = agent
            self.conversations[conv_id].append(msg)
            self._save()

    def get_history(self, conv_id):
        with self.lock:
            return list(self.conversations.get(conv_id, []))

    def list_conversations(self):
        with self.lock:
            result = []
            for cid, msgs in self.conversations.items():
                if msgs:
                    result.append({
                        "id": cid,
                        "message_count": len(msgs),
                        "last_message": msgs[-1].get("content", "")[:80],
                        "updated_at": msgs[-1].get("timestamp", 0),
                    })
            return sorted(result, key=lambda x: x["updated_at"], reverse=True)


conversations = ConversationManager()

# ---------------------------------------------------------------------------
# Agent Router
# ---------------------------------------------------------------------------

def _extract_delegation(response):
    """Detect [DELEGATE:AGENT] anywhere in response. Returns (agent_name, cleaned_text) or (None, response)."""
    import re
    m = re.search(r'\[DELEGATE:(\w+)\]', response or "")
    if m:
        agent = m.group(1).strip().lower()
        # Strip all delegation markers from text
        cleaned = re.sub(r'\[DELEGATE:\w+\]\s*', '', response).strip()
        return agent, cleaned
    return None, response


def route_and_respond(user_message, conv_id=None):
    """Route user message through agent system. Returns (response, agent_name, conv_id)."""
    conv_id, history = conversations.get_or_create(conv_id)
    conversations.add_message(conv_id, "user", user_message)

    # Build messages for router
    system_prompt = build_agent_system_prompt("router")
    messages = [{"role": "system", "content": system_prompt}]

    # Add conversation history (last 10 messages)
    for msg in history[-10:]:
        messages.append({"role": msg["role"], "content": msg["content"]})
    messages.append({"role": "user", "content": user_message})

    # Call router
    response = call_llm(messages)

    # Check for delegation (anywhere in response)
    agent_name = "router"
    delegate_to, response = _extract_delegation(response)
    if delegate_to and delegate_to in AGENT_PROMPTS:
        agent_name = delegate_to
        specialist_prompt = build_agent_system_prompt(agent_name)
        messages[0] = {"role": "system", "content": specialist_prompt}
        response = call_llm(messages)
        # Clean any stray delegation markers from specialist response too
        _, response = _extract_delegation(response)

    conversations.add_message(conv_id, "assistant", response or "(no response)", agent=agent_name)

    # Try search integration for discovery questions
    search_keywords = ["find", "search", "where", "which projects", "what uses", "show me"]
    if any(kw in user_message.lower() for kw in search_keywords):
        try:
            from search_index import search as fts_search
            results = fts_search(user_message)
            if results:
                search_context = "\n\n---\nSearch results:\n" + "\n".join(
                    f"- {r['title']} ({r['scope']}): {r['snippet']}" for r in results[:5]
                )
                response = (response or "") + search_context
        except Exception:
            pass

    return response or "(no response)", agent_name, conv_id


def route_and_stream(user_message, conv_id=None):
    """Route user message and yield SSE chunks. Returns (generator, agent_name, conv_id)."""
    conv_id, history = conversations.get_or_create(conv_id)
    conversations.add_message(conv_id, "user", user_message)

    system_prompt = build_agent_system_prompt("router")
    messages = [{"role": "system", "content": system_prompt}]
    for msg in history[-10:]:
        messages.append({"role": msg["role"], "content": msg["content"]})
    messages.append({"role": "user", "content": user_message})

    cfg = load_ai_config()
    agent_name = "router"

    # For streaming, use non-streaming first call to check delegation,
    # then stream the actual response
    try:
        response = call_llm(messages, cfg, stream=False)
        delegate_to, response = _extract_delegation(response)
        if delegate_to and delegate_to in AGENT_PROMPTS:
            agent_name = delegate_to
            messages[0] = {"role": "system", "content": build_agent_system_prompt(agent_name)}
            response = call_llm(messages, cfg, stream=False)
            _, response = _extract_delegation(response)

        conversations.add_message(conv_id, "assistant", response or "(no response)", agent=agent_name)
    except Exception as e:
        response = f"(Error: {e})"
        conversations.add_message(conv_id, "assistant", response, agent=agent_name)

    return response, agent_name, conv_id


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------

class ChatHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress default logging

    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json_response(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self._cors_headers()
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length:
            return json.loads(self.rfile.read(length))
        return {}

    def do_OPTIONS(self):
        self.send_response(200)
        self._cors_headers()
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            cfg = load_ai_config()
            self._json_response({
                "status": "ok",
                "version": "2.3.0",
                "backend": cfg["backend"],
                "model": cfg["model"],
                "uptime": time.time() - _start_time,
            })

        elif self.path == "/agents":
            agents = []
            for name, prompt in AGENT_PROMPTS.items():
                agents.append({
                    "name": name,
                    "description": prompt.split(".")[0],
                    "type": "router" if name == "router" else "specialist",
                })
            self._json_response({"agents": agents})

        elif self.path.startswith("/history"):
            # Parse query params
            parts = self.path.split("?", 1)
            params = {}
            if len(parts) > 1:
                for p in parts[1].split("&"):
                    kv = p.split("=", 1)
                    if len(kv) == 2:
                        params[kv[0]] = kv[1]

            conv_id = params.get("id")
            if conv_id:
                history = conversations.get_history(conv_id)
                self._json_response({"conversation_id": conv_id, "messages": history})
            else:
                self._json_response({"conversations": conversations.list_conversations()})

        else:
            self._json_response({"error": "not found"}, 404)

    def do_POST(self):
        if self.path == "/chat":
            body = self._read_body()
            message = body.get("message", "").strip()
            conv_id = body.get("conversation_id")
            stream = body.get("stream", False)

            if not message:
                self._json_response({"error": "message required"}, 400)
                return

            if stream:
                # SSE streaming response
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self._cors_headers()
                self.end_headers()

                response, agent, cid = route_and_stream(message, conv_id)

                # Send agent info
                self.wfile.write(f"event: agent\ndata: {json.dumps({'agent': agent, 'conversation_id': cid})}\n\n".encode())
                self.wfile.flush()

                # Stream content character by character (simulate streaming for non-stream backends)
                chunk_size = 20
                for i in range(0, len(response), chunk_size):
                    chunk = response[i:i + chunk_size]
                    self.wfile.write(f"data: {json.dumps({'content': chunk})}\n\n".encode())
                    self.wfile.flush()
                    time.sleep(0.02)

                self.wfile.write(b"event: done\ndata: {}\n\n")
                self.wfile.flush()
            else:
                response, agent, cid = route_and_respond(message, conv_id)
                self._json_response({
                    "response": response,
                    "agent": agent,
                    "conversation_id": cid,
                })

        elif self.path == "/search":
            body = self._read_body()
            query = body.get("query", "").strip()
            scope = body.get("scope", ["projects", "filesystem", "history"])

            if not query:
                self._json_response({"error": "query required"}, 400)
                return

            try:
                sys.path.insert(0, str(LFG_DIR / "lib"))
                from search_index import search
                results = search(query, scope=scope)
                self._json_response({"query": query, "results": results})
            except Exception as e:
                self._json_response({"query": query, "results": [], "error": str(e)})

        else:
            self._json_response({"error": "not found"}, 404)


# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------

_start_time = time.time()
_server_instance: Optional[HTTPServer] = None
_pid_file = CONFIG_DIR / "chat_server.pid"


def _log_info(msg: str) -> None:
    print(f"[LFG-CHAT INFO] {msg}", file=sys.stderr)


def _log_error(msg: str) -> None:
    print(f"[LFG-CHAT ERROR] {msg}", file=sys.stderr)


def _is_pid_alive(pid: int) -> bool:
    """Check whether a process is still running."""
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def _cleanup_stale_pid() -> None:
    """Remove PID file if it references a dead process."""
    if not _pid_file.exists():
        return
    try:
        raw = _pid_file.read_text().strip()
        if not raw:
            _pid_file.unlink(missing_ok=True)
            return
        pid = int(raw)
        if not _is_pid_alive(pid):
            _log_info(f"Cleaning stale PID file (pid {pid} not running)")
            _pid_file.unlink(missing_ok=True)
        else:
            _log_error(f"Chat server already running (pid {pid})")
            sys.exit(1)
    except (ValueError, OSError) as exc:
        _log_error(f"Corrupt PID file, removing: {exc}")
        _pid_file.unlink(missing_ok=True)


def _shutdown_handler(signum: int, frame: Any) -> None:
    """Handle SIGTERM/SIGINT for graceful shutdown."""
    sig_name = signal.Signals(signum).name if hasattr(signal, "Signals") else str(signum)
    _log_info(f"Received {sig_name}, shutting down...")
    if _server_instance is not None:
        _server_instance.server_close()
    _pid_file.unlink(missing_ok=True)
    sys.exit(0)


def run_server(port: int = 3033) -> None:
    """Start the chat server daemon with graceful shutdown support."""
    global _start_time, _server_instance

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    _cleanup_stale_pid()
    _pid_file.write_text(str(os.getpid()))
    _start_time = time.time()

    signal.signal(signal.SIGTERM, _shutdown_handler)
    signal.signal(signal.SIGINT, _shutdown_handler)

    try:
        HTTPServer.allow_reuse_address = True
        server = HTTPServer(("127.0.0.1", port), ChatHandler)
    except OSError as exc:
        _log_error(f"Failed to bind to port {port}: {exc}")
        _pid_file.unlink(missing_ok=True)
        sys.exit(1)

    _server_instance = server
    print(f"LFG Chat Server listening on http://localhost:{port}")

    try:
        server.serve_forever()
    finally:
        server.server_close()
        _pid_file.unlink(missing_ok=True)
        _log_info("Server stopped.")


def stop_server() -> None:
    """Stop a running chat server via its PID file."""
    if not _pid_file.exists():
        print("Chat server not running")
        return
    try:
        pid = int(_pid_file.read_text().strip())
    except (ValueError, OSError) as exc:
        _log_error(f"Cannot read PID file: {exc}")
        _pid_file.unlink(missing_ok=True)
        return
    if not _is_pid_alive(pid):
        print("Chat server not running (stale PID cleaned up)")
        _pid_file.unlink(missing_ok=True)
        return
    try:
        os.kill(pid, signal.SIGTERM)
        print("Chat server stopped")
    except OSError as exc:
        _log_error(f"Failed to stop server (pid {pid}): {exc}")
    finally:
        _pid_file.unlink(missing_ok=True)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "stop":
        stop_server()
    else:
        port = 3033
        if len(sys.argv) > 1:
            try:
                port = int(sys.argv[1])
            except ValueError:
                pass
        run_server(port)
