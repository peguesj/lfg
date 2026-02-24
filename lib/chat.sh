#!/usr/bin/env bash
# =============================================================================
# lfg chat - Dedicated chat view with agent roster and semantic search
# =============================================================================
set -uo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$LFG_DIR/lib/state.sh"
LFG_MODULE="chat"
HTML_FILE="$LFG_CACHE_DIR/.lfg_chat.html"
VIEWER="$LFG_DIR/viewer"
CHAT_SERVER="$LFG_DIR/lib/chat_server.py"
CHAT_PID_FILE="$HOME/.config/lfg/chat_server.pid"

# Ensure chat server is running
ensure_chat_server() {
    if [[ -f "$CHAT_PID_FILE" ]] && kill -0 "$(cat "$CHAT_PID_FILE")" 2>/dev/null; then
        return 0
    fi
    echo "Starting chat server..."
    python3 "$CHAT_SERVER" &
    disown
    sleep 1
}

# CLI mode: lfg chat send "message"
if [[ "${1:-}" == "send" ]]; then
    shift
    local_msg="${*}"
    [[ -z "$local_msg" ]] && { echo "Usage: lfg chat send \"message\""; exit 1; }
    ensure_chat_server
    python3 -c "
import json, urllib.request
payload = json.dumps({'message': '''$local_msg'''}).encode()
req = urllib.request.Request(
    'http://localhost:3033/chat',
    data=payload,
    headers={'Content-Type': 'application/json'},
)
try:
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read())
        agent = data.get('agent', 'router')
        print(f'[{agent}] {data.get(\"response\", \"(no response)\")}')
except Exception as e:
    print(f'Error: {e}')
"
    exit 0
fi

ensure_chat_server

export LFG_DIR HTML_FILE

python3 << 'PYEOF'
import os

lfg_dir = os.environ.get("LFG_DIR", os.path.expanduser("~/tools/@yj/lfg"))
html_file = os.environ.get("HTML_FILE", lfg_dir + "/.lfg_chat.html")

theme_css = open(f"{lfg_dir}/lib/theme.css").read()
ui_js = open(f"{lfg_dir}/lib/ui.js").read()

html = f'''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
{theme_css}

:root {{
  --chat-bg: #141418;
  --msg-user: #1c2a3d;
  --msg-bot: #1c1c22;
  --agent-router: #4a9eff;
  --agent-wtfs: #4a9eff;
  --agent-dtf: #ff8c42;
  --agent-btau: #06d6a0;
  --agent-devdrive: #c084fc;
  --agent-stfu: #e879f9;
}}

body {{
  user-select: none;
}}

/* Agent Roster Sidebar */
.chat-sidebar {{
  width: 200px;
  min-height: 100vh;
  background: #111115;
  border-right: 1px solid #2a2a34;
  display: flex;
  flex-direction: column;
  padding: 48px 12px 12px;
  flex-shrink: 0;
}}
.chat-sidebar-title {{
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 1px;
  color: #6b6b78;
  margin-bottom: 12px;
}}
.agent-item {{
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 10px;
  border-radius: 6px;
  font-size: 11px;
  color: #a0a0b0;
  cursor: default;
  margin-bottom: 2px;
  transition: background 0.15s;
}}
.agent-item:hover {{ background: rgba(255,255,255,0.04); }}
.agent-item .agent-wm {{
  display: flex;
  align-items: baseline;
  gap: 1px;
  line-height: 1;
}}
.agent-item .agent-wm-lfg {{
  font-size: 11px;
  font-weight: 900;
  letter-spacing: -0.3px;
  color: #6b6b78;
}}
.agent-item .agent-wm-label {{
  font-size: 7px;
  font-weight: 800;
  text-transform: uppercase;
  letter-spacing: 0.8px;
  margin-left: 3px;
}}
.agent-item .agent-type {{ font-size: 9px; color: #4a4a56; margin-top: 1px; }}
.agent-item.active {{ background: rgba(74,158,255,0.1); }}
.agent-item.active .agent-wm-lfg {{ color: #fff; }}

/* Search bar */
.chat-search {{
  margin-top: auto;
  padding-top: 12px;
  border-top: 1px solid #2a2a34;
}}
.chat-search input {{
  width: 100%;
  background: #1c1c22;
  border: 1px solid #2a2a34;
  border-radius: 6px;
  color: #e0e0e6;
  padding: 8px 10px;
  font-size: 11px;
  font-family: inherit;
  outline: none;
}}
.chat-search input:focus {{ border-color: #4a9eff; }}
.chat-search input::placeholder {{ color: #4a4a56; }}

/* Main chat area */
.chat-main {{
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}}

/* Message list */
.chat-messages {{
  flex: 1;
  overflow-y: auto;
  padding: 52px 32px 16px;
  display: flex;
  flex-direction: column;
  gap: 12px;
}}

/* Message bubble */
.chat-msg {{
  max-width: 720px;
  padding: 12px 16px;
  border-radius: 12px;
  font-size: 13px;
  line-height: 1.6;
  animation: msgIn 0.3s ease-out;
  word-wrap: break-word;
}}
@keyframes msgIn {{
  from {{ opacity: 0; transform: translateY(8px); }}
  to {{ opacity: 1; transform: translateY(0); }}
}}
.chat-msg.user {{
  background: var(--msg-user);
  border: 1px solid rgba(74,158,255,0.2);
  align-self: flex-end;
  border-bottom-right-radius: 4px;
}}
.chat-msg.assistant {{
  background: var(--msg-bot);
  border: 1px solid #2a2a34;
  align-self: flex-start;
  border-bottom-left-radius: 4px;
}}
/* LFG wordmark badge */
.msg-agent-badge {{
  display: inline-flex;
  align-items: baseline;
  gap: 1px;
  margin-bottom: 8px;
  line-height: 1;
}}
.msg-agent-badge .wm-lfg {{
  font-size: 15px;
  font-weight: 900;
  letter-spacing: -0.5px;
  color: #fff;
}}
.msg-agent-badge .wm-label {{
  font-size: 9px;
  font-weight: 800;
  text-transform: uppercase;
  letter-spacing: 1.2px;
  margin-left: 5px;
  position: relative;
  top: 0.5px;
}}
.chat-msg .msg-copy {{
  position: absolute;
  top: 8px; right: 8px;
  background: #2a2a34;
  border: none;
  color: #6b6b78;
  font-size: 10px;
  padding: 2px 6px;
  border-radius: 4px;
  cursor: pointer;
  opacity: 0;
  transition: opacity 0.15s;
}}
.chat-msg:hover .msg-copy {{ opacity: 1; }}
.chat-msg pre {{
  background: #0d0d10;
  border: 1px solid #2a2a34;
  border-radius: 6px;
  padding: 10px 12px;
  font-size: 12px;
  overflow-x: auto;
  margin: 8px 0;
}}
.chat-msg code {{
  background: #2a2a34;
  padding: 1px 5px;
  border-radius: 3px;
  font-size: 12px;
  color: #4a9eff;
}}
.chat-msg pre code {{
  background: none;
  padding: 0;
  color: #e0e0e6;
}}

/* Quick actions */
.chat-chips {{
  padding: 0 32px 8px;
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
}}
.chat-chip {{
  padding: 6px 12px;
  background: #1c1c22;
  border: 1px solid #2a2a34;
  border-radius: 16px;
  font-size: 11px;
  color: #a0a0b0;
  cursor: pointer;
  transition: all 0.15s;
  font-family: inherit;
}}
.chat-chip:hover {{
  border-color: #4a9eff;
  color: #4a9eff;
  background: rgba(74,158,255,0.08);
}}

/* Input area */
.chat-input-wrap {{
  padding: 12px 32px 20px;
  border-top: 1px solid #1e1e28;
  display: flex;
  gap: 8px;
  align-items: flex-end;
}}
.chat-input {{
  flex: 1;
  background: #1c1c22;
  border: 1px solid #2a2a34;
  border-radius: 12px;
  color: #e0e0e6;
  padding: 12px 16px;
  font-size: 13px;
  font-family: inherit;
  outline: none;
  resize: none;
  min-height: 20px;
  max-height: 120px;
  line-height: 1.4;
}}
.chat-input:focus {{ border-color: #4a9eff; }}
.chat-input::placeholder {{ color: #4a4a56; }}
.chat-send {{
  background: #4a9eff;
  border: none;
  border-radius: 10px;
  color: #fff;
  width: 40px; height: 40px;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  font-size: 16px;
  transition: background 0.15s;
  flex-shrink: 0;
}}
.chat-send:hover {{ background: #3a8eef; }}
.chat-send:disabled {{ background: #2a2a34; cursor: default; }}

/* Search results */
.search-result {{
  padding: 10px 14px;
  background: #1c1c22;
  border: 1px solid #2a2a34;
  border-radius: 8px;
  margin: 4px 0;
  font-size: 11px;
}}
.search-result .sr-scope {{
  font-size: 9px;
  font-weight: 600;
  text-transform: uppercase;
  color: #4a9eff;
  letter-spacing: 0.5px;
}}
.search-result .sr-title {{
  font-weight: 600;
  color: #e0e0e6;
  margin-top: 2px;
}}
.search-result .sr-snippet {{
  color: #6b6b78;
  margin-top: 2px;
}}
</style>
</head>
<body>
  <!-- Agent Roster Sidebar -->
  <aside class="chat-sidebar">
    <div class="chat-sidebar-title">Agents</div>
    <div class="agent-item active" id="agent-router">
      <div>
        <div class="agent-wm"><span class="agent-wm-lfg">LFG</span><span class="agent-wm-label" style="color:#4a9eff">ROUTER</span></div>
        <div class="agent-type">Intent analysis</div>
      </div>
    </div>
    <div class="agent-item" id="agent-wtfs">
      <div>
        <div class="agent-wm"><span class="agent-wm-lfg">LFG</span><span class="agent-wm-label" style="color:#4a9eff">WTFS</span></div>
        <div class="agent-type">Disk usage</div>
      </div>
    </div>
    <div class="agent-item" id="agent-dtf">
      <div>
        <div class="agent-wm"><span class="agent-wm-lfg">LFG</span><span class="agent-wm-label" style="color:#ff8c42">DTF</span></div>
        <div class="agent-type">Cache cleanup</div>
      </div>
    </div>
    <div class="agent-item" id="agent-btau">
      <div>
        <div class="agent-wm"><span class="agent-wm-lfg">LFG</span><span class="agent-wm-label" style="color:#06d6a0">BTAU</span></div>
        <div class="agent-type">Backup mgmt</div>
      </div>
    </div>
    <div class="agent-item" id="agent-devdrive">
      <div>
        <div class="agent-wm"><span class="agent-wm-lfg">LFG</span><span class="agent-wm-label" style="color:#c084fc">DEVDRIVE</span></div>
        <div class="agent-type">Volume mgmt</div>
      </div>
    </div>
    <div class="agent-item" id="agent-stfu">
      <div>
        <div class="agent-wm"><span class="agent-wm-lfg">LFG</span><span class="agent-wm-label" style="color:#e879f9">STFU</span></div>
        <div class="agent-type">Code forensics</div>
      </div>
    </div>

    <div class="chat-search">
      <input type="text" id="search-input" placeholder="Search projects, files..."
             onkeydown="if(event.key==='Enter')doSearch()">
    </div>
  </aside>

  <!-- Main Chat Area -->
  <div class="chat-main">
    <div class="chat-messages" id="messages">
      <div class="chat-msg assistant" style="position:relative">
        <div class="msg-agent-badge"><span class="wm-lfg">LFG</span><span class="wm-label" style="color:#4a9eff">ROUTER</span></div>
        Welcome to LFG Chat. I can help you manage disk space, clean caches,
        check backups, and more. Ask me anything about your system.
      </div>
    </div>

    <div class="chat-chips">
      <button class="chat-chip" onclick="sendMessage('What\\'s using the most space?')">What's using the most space?</button>
      <button class="chat-chip" onclick="sendMessage('Clean safe caches')">Clean safe caches</button>
      <button class="chat-chip" onclick="sendMessage('Check backup status')">Check backup status</button>
      <button class="chat-chip" onclick="sendMessage('Show devdrive health')">Show devdrive health</button>
      <button class="chat-chip" onclick="sendMessage('Find duplicate projects')">Find duplicate projects</button>
    </div>

    <div class="chat-input-wrap">
      <textarea class="chat-input" id="chat-input" rows="1"
                placeholder="Ask LFG anything..."
                onkeydown="if(event.key==='Enter'&&!event.shiftKey){{event.preventDefault();sendMessage()}}"></textarea>
      <button class="chat-send" id="send-btn" onclick="sendMessage()">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>
      </button>
    </div>
  </div>

  <script>
{ui_js}

LFG.init({{ module: "chat", context: "AI Chat", moduleVersion: "2.3.1", helpContent: "<strong>LFG Chat</strong><br><br>AI-powered chat for disk management. Ask questions about disk usage, cache cleanup, backups, and developer drive.<br><br>The chat server runs locally at <code>localhost:3033</code>. Start with: <code>python3 lib/chat_server.py &amp;</code>" }});

var conversationId = null;
var agentColors = {{
  router: '#4a9eff', wtfs: '#4a9eff', dtf: '#ff8c42',
  btau: '#06d6a0', devdrive: '#c084fc', stfu: '#e879f9'
}};

function addMessage(role, content, agent) {{
  var el = document.getElementById('messages');
  var msg = document.createElement('div');
  msg.className = 'chat-msg ' + role;
  msg.style.position = 'relative';

  var html = '';
  if (role === 'assistant' && agent) {{
    var color = agentColors[agent] || '#4a9eff';
    html += '<div class="msg-agent-badge"><span class="wm-lfg">LFG</span>';
    html += '<span class="wm-label" style="color:' + color + '">' + agent.toUpperCase() + '</span></div>';

    // Highlight active agent in sidebar
    document.querySelectorAll('.agent-item').forEach(function(a) {{ a.classList.remove('active'); }});
    var agentEl = document.getElementById('agent-' + agent);
    if (agentEl) agentEl.classList.add('active');
  }}

  // Basic markdown: code blocks, inline code, bold
  var rendered = content
    .replace(/```(\\w*)\\n([\\s\\S]*?)```/g, '<pre><code>$2</code></pre>')
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\\*\\*([^*]+)\\*\\*/g, '<strong>$1</strong>')
    .replace(/\\n/g, '<br>');

  html += rendered;

  // Copy button
  html += '<button class="msg-copy" onclick="navigator.clipboard.writeText(this.parentElement.innerText);LFG.toast(\\'Copied!\\',{{type:\\'success\\',duration:1200}})">Copy</button>';

  msg.innerHTML = html;
  el.appendChild(msg);
  el.scrollTop = el.scrollHeight;
}}

function sendMessage(text) {{
  var input = document.getElementById('chat-input');
  var message = text || input.value.trim();
  if (!message) return;
  input.value = '';

  addMessage('user', message);

  var sendBtn = document.getElementById('send-btn');
  sendBtn.disabled = true;

  // Use SSE streaming
  var body = JSON.stringify({{
    message: message,
    conversation_id: conversationId,
    stream: true
  }});

  fetch('http://localhost:3033/chat', {{
    method: 'POST',
    headers: {{ 'Content-Type': 'application/json' }},
    body: body
  }}).then(function(resp) {{
    if (!resp.ok) throw new Error('Chat server error');
    var reader = resp.body.getReader();
    var decoder = new TextDecoder();
    var buffer = '';
    var agent = 'router';
    var fullContent = '';
    var msgEl = null;

    function processChunk() {{
      reader.read().then(function(result) {{
        if (result.done) {{
          sendBtn.disabled = false;
          return;
        }}
        buffer += decoder.decode(result.value, {{ stream: true }});
        var lines = buffer.split('\\n');
        buffer = lines.pop();

        lines.forEach(function(line) {{
          if (line.startsWith('event: agent')) return;
          if (line.startsWith('event: done')) {{
            sendBtn.disabled = false;
            return;
          }}
          if (line.startsWith('data: ')) {{
            try {{
              var data = JSON.parse(line.substring(6));
              if (data.agent) {{
                agent = data.agent;
                conversationId = data.conversation_id;
              }}
              if (data.content) {{
                fullContent += data.content;
                if (!msgEl) {{
                  addMessage('assistant', '', agent);
                  msgEl = document.getElementById('messages').lastElementChild;
                }}
                // Update content
                var color = agentColors[agent] || '#4a9eff';
                var rendered = fullContent
                  .replace(/```(\\w*)\\n([\\s\\S]*?)```/g, '<pre><code>$2</code></pre>')
                  .replace(/`([^`]+)`/g, '<code>$1</code>')
                  .replace(/\\*\\*([^*]+)\\*\\*/g, '<strong>$1</strong>')
                  .replace(/\\n/g, '<br>');
                msgEl.innerHTML = '<div class="msg-agent-badge"><span class="wm-lfg">LFG</span><span class="wm-label" style="color:' + color + '">' + agent.toUpperCase() + '</span></div>' + rendered + '<button class="msg-copy" onclick="navigator.clipboard.writeText(this.parentElement.innerText);LFG.toast(\\'Copied!\\',{{type:\\'success\\',duration:1200}})">Copy</button>';
                document.getElementById('messages').scrollTop = document.getElementById('messages').scrollHeight;
              }}
            }} catch(e) {{}}
          }}
        }});
        processChunk();
      }});
    }}
    processChunk();
  }}).catch(function(err) {{
    addMessage('assistant', 'Chat server unavailable. Start with: python3 lib/chat_server.py &', 'router');
    sendBtn.disabled = false;
  }});
}}

function doSearch() {{
  var q = document.getElementById('search-input').value.trim();
  if (!q) return;

  fetch('http://localhost:3033/search', {{
    method: 'POST',
    headers: {{ 'Content-Type': 'application/json' }},
    body: JSON.stringify({{ query: q }})
  }}).then(function(r) {{ return r.json(); }}).then(function(data) {{
    var results = data.results || [];
    if (results.length === 0) {{
      addMessage('assistant', 'No results found for "' + q + '". Try rebuilding the index with: lfg search index', 'router');
      return;
    }}
    var html = 'Search results for "' + q + '":\\n\\n';
    results.slice(0, 8).forEach(function(r) {{
      html += '**[' + r.scope + ']** ' + r.title + '\\n';
      if (r.path) html += '`' + r.path + '`\\n';
      html += r.snippet.substring(0, 120) + '\\n\\n';
    }});
    addMessage('assistant', html, 'router');
  }}).catch(function() {{
    addMessage('assistant', 'Search unavailable. Ensure chat server is running.', 'router');
  }});
}}

// Auto-resize textarea
document.getElementById('chat-input').addEventListener('input', function() {{
  this.style.height = 'auto';
  this.style.height = Math.min(this.scrollHeight, 120) + 'px';
}});

// Keyboard: Cmd+6 for chat
document.addEventListener('keydown', function(e) {{
  if (e.metaKey && e.key === '6') {{
    document.getElementById('chat-input').focus();
    e.preventDefault();
  }}
}});
  </script>
</body>
</html>'''

with open(html_file, 'w') as f:
    f.write(html)
PYEOF

# Launch viewer
if [[ "${LFG_NO_VIEWER:-}" == "1" ]]; then
    echo "Done (headless)."
else
    "$VIEWER" "$HTML_FILE" "LFG Chat" &
    disown
    echo "LFG Chat launched."
fi
