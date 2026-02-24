// =============================================================================
// LFG UI Module v2.3.2 - Shared JavaScript for all LFG views
// Provides: omnipresent icon rail shell, toasters, tooltips, help overlay,
//           row selection, guided tours, cross-module actions, kbd nav, exec bridge,
//           notifications system
// =============================================================================

const LFG = {
  version: '2.3.2',

  // Module registry for rail icons
  _modules: [
    { id: 'wtfs',     label: 'WTFS',     key: '1', icon: '<svg viewBox="0 0 24 24" width="20" height="20"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>' },
    { id: 'dtf',      label: 'DTF',      key: '2', icon: '<svg viewBox="0 0 24 24" width="20" height="20"><path d="M3 12l2 2 4-4"/><line x1="10" y1="12" x2="21" y2="12"/><line x1="10" y1="6" x2="21" y2="6"/><line x1="10" y1="18" x2="21" y2="18"/></svg>' },
    { id: 'btau',     label: 'BTAU',     key: '3', icon: '<svg viewBox="0 0 24 24" width="20" height="20"><circle cx="12" cy="12" r="4"/><path d="M12 2v4M12 18v4M2 12h4M18 12h4"/></svg>' },
    { id: 'devdrive', label: 'DEVDRIVE', key: '4', icon: '<svg viewBox="0 0 24 24" width="20" height="20"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/></svg>' },
    { id: 'stfu',     label: 'STFU',     key: '5', icon: '<svg viewBox="0 0 24 24" width="20" height="20"><path d="M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2z"/></svg>' },
  ],

  _utilModules: [
    { id: 'chat',     label: 'Chat',     key: '6', icon: '<svg viewBox="0 0 24 24" width="20" height="20"><path d="M21 15a2 2 0 01-2 2H7l-4 4V5a2 2 0 012-2h14a2 2 0 012 2z"/></svg>' },
    { id: 'dashboard',label: 'Dash',     key: 'd', icon: '<svg viewBox="0 0 24 24" width="20" height="20"><polygon points="12 2 2 7 12 12 22 7"/><polyline points="2 12 12 17 22 12"/></svg>' },
  ],

  // --- Notifications System ---
  notifications: {
    _list: [],
    _el: null,
    _badge: null,

    _load() {
      try { LFG.notifications._list = JSON.parse(localStorage.getItem('lfg-notifications') || '[]'); } catch(e) { LFG.notifications._list = []; }
    },
    _save() {
      localStorage.setItem('lfg-notifications', JSON.stringify(LFG.notifications._list.slice(0, 50)));
    },
    add(msg, type) {
      type = type || 'info';
      LFG.notifications._list.unshift({ msg: msg, type: type, time: Date.now() });
      LFG.notifications._save();
      LFG.notifications._updateBadge();
    },
    _updateBadge() {
      var badge = LFG.notifications._badge;
      if (!badge) return;
      var unread = LFG.notifications._list.filter(function(n) { return !n.read; }).length;
      badge.textContent = unread > 9 ? '9+' : unread;
      badge.style.display = unread > 0 ? 'flex' : 'none';
      // US-008: Update native dock tile badge
      try {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lfg) {
          window.webkit.messageHandlers.lfg.postMessage({ action: 'badge', count: unread });
        }
      } catch(e) {}
    },
    _toggle() {
      var panel = document.getElementById('lfg-notif-panel');
      if (panel) { panel.remove(); return; }
      panel = document.createElement('div');
      panel.id = 'lfg-notif-panel';
      panel.className = 'rail-notif-panel';
      var list = LFG.notifications._list;
      if (list.length === 0) {
        panel.innerHTML = '<div class="rail-notif-empty">No notifications</div>';
      } else {
        var html = '<div class="rail-notif-header">Notifications<button onclick="LFG.notifications.clear()" class="rail-notif-clear">Clear</button></div>';
        list.slice(0, 20).forEach(function(n) {
          var ago = LFG.notifications._timeAgo(n.time);
          html += '<div class="rail-notif-item rail-notif-' + n.type + '"><span class="rail-notif-msg">' + n.msg + '</span><span class="rail-notif-time">' + ago + '</span></div>';
        });
        panel.innerHTML = html;
      }
      // Mark all read
      list.forEach(function(n) { n.read = true; });
      LFG.notifications._save();
      LFG.notifications._updateBadge();
      document.querySelector('.lfg-rail').appendChild(panel);
    },
    clear() {
      LFG.notifications._list = [];
      LFG.notifications._save();
      LFG.notifications._updateBadge();
      var panel = document.getElementById('lfg-notif-panel');
      if (panel) panel.remove();
    },
    _timeAgo(ts) {
      var s = Math.floor((Date.now() - ts) / 1000);
      if (s < 60) return 'now';
      if (s < 3600) return Math.floor(s / 60) + 'm';
      if (s < 86400) return Math.floor(s / 3600) + 'h';
      return Math.floor(s / 86400) + 'd';
    }
  },

  // --- Toaster Notification System ---
  toast: (() => {
    let container = null;
    function ensureContainer() {
      if (container) return container;
      container = document.createElement('div');
      container.id = 'lfg-toaster';
      container.style.cssText = `
        position:fixed; bottom:44px; right:16px; z-index:9999;
        display:flex; flex-direction:column-reverse; gap:8px;
        pointer-events:none; max-width:320px;
      `;
      document.body.appendChild(container);
      return container;
    }
    return function(message, opts = {}) {
      const c = ensureContainer();
      const type = opts.type || 'info';
      const duration = opts.duration || 3500;
      const colors = {
        info: { bg: '#1c2a3d', border: '#4a9eff', icon: '\u2139\uFE0F' },
        success: { bg: '#1c2d24', border: '#06d6a0', icon: '\u2705' },
        warning: { bg: '#2d2a1c', border: '#ff8c42', icon: '\u26A0\uFE0F' },
        error: { bg: '#2d1c1c', border: '#ff4d6a', icon: '\u274C' },
      };
      const s = colors[type] || colors.info;
      const el = document.createElement('div');
      el.style.cssText = `
        background:${s.bg}; border:1px solid ${s.border}; border-radius:8px;
        padding:10px 14px; font-size:12px; color:#e0e0e6;
        pointer-events:auto; cursor:pointer; display:flex; align-items:center; gap:8px;
        opacity:0; transform:translateX(20px);
        transition: opacity 0.3s ease, transform 0.3s ease;
        box-shadow: 0 4px 16px rgba(0,0,0,0.3);
        font-family: -apple-system, BlinkMacSystemFont, "SF Mono", Menlo, monospace;
      `;
      el.innerHTML = `<span style="font-size:14px">${s.icon}</span><span>${message}</span>`;
      el.onclick = () => dismiss(el);
      c.appendChild(el);
      requestAnimationFrame(() => {
        el.style.opacity = '1';
        el.style.transform = 'translateX(0)';
      });
      const timer = setTimeout(() => dismiss(el), duration);
      function dismiss(e) {
        clearTimeout(timer);
        e.style.opacity = '0';
        e.style.transform = 'translateX(20px)';
        setTimeout(() => e.remove(), 300);
      }
    };
  })(),

  // --- Tooltip System ---
  initTooltips() {
    const tip = document.createElement('div');
    tip.id = 'lfg-tooltip';
    tip.style.cssText = `
      position:fixed; z-index:9998; padding:6px 10px;
      background:#1c1c22; border:1px solid #3a3a44; border-radius:6px;
      font-size:11px; color:#a0a0b0; pointer-events:none;
      opacity:0; transition:opacity 0.15s; max-width:240px;
      font-family: -apple-system, BlinkMacSystemFont, "SF Mono", Menlo, monospace;
      box-shadow: 0 4px 12px rgba(0,0,0,0.4);
    `;
    document.body.appendChild(tip);

    document.addEventListener('mouseover', e => {
      const el = e.target.closest('[data-tip]');
      if (!el) return;
      tip.textContent = el.dataset.tip;
      tip.style.opacity = '1';
    });
    document.addEventListener('mousemove', e => {
      tip.style.left = (e.clientX + 12) + 'px';
      tip.style.top = (e.clientY - 32) + 'px';
    });
    document.addEventListener('mouseout', e => {
      if (e.target.closest('[data-tip]')) tip.style.opacity = '0';
    });
  },

  // --- Getting Started Showcase (legacy, kept for dashboard onboarding) ---
  showOnboarding(steps) {
    if (localStorage.getItem('lfg-onboarded')) return;
    let idx = 0;
    const overlay = document.createElement('div');
    overlay.id = 'lfg-onboarding';
    overlay.style.cssText = `
      position:fixed; inset:0; z-index:10000;
      background:rgba(10,10,14,0.85); display:flex;
      align-items:center; justify-content:center;
      backdrop-filter:blur(4px);
    `;
    function render() {
      const step = steps[idx];
      overlay.innerHTML = `
        <div style="
          background:#1c1c22; border:1px solid #2a2a34; border-radius:12px;
          padding:32px 36px; max-width:440px; text-align:center;
          animation: lfgFadeIn 0.3s ease;
        ">
          <div style="font-size:36px; margin-bottom:12px">${step.icon}</div>
          <div style="font-size:16px; font-weight:700; color:#fff; margin-bottom:6px">${step.title}</div>
          <div style="font-size:12px; color:#a0a0b0; line-height:1.6; margin-bottom:20px">${step.desc}</div>
          <div style="display:flex; gap:8px; justify-content:center">
            ${idx > 0 ? '<button id="ob-prev" style="' + LFG._btnStyle('#2a2a34') + '">Back</button>' : ''}
            <button id="ob-next" style="${LFG._btnStyle(step.color || '#4a9eff')}">${idx < steps.length - 1 ? 'Next' : "Let's Go"}</button>
          </div>
          <div style="margin-top:14px; display:flex; gap:6px; justify-content:center">
            ${steps.map((_, i) => `<div style="width:8px; height:8px; border-radius:50%; background:${i === idx ? '#4a9eff' : '#2a2a34'}"></div>`).join('')}
          </div>
        </div>
      `;
      const next = overlay.querySelector('#ob-next');
      const prev = overlay.querySelector('#ob-prev');
      if (next) next.onclick = () => {
        if (idx < steps.length - 1) { idx++; render(); }
        else { localStorage.setItem('lfg-onboarded', '1'); overlay.remove(); LFG.toast('Welcome to LFG!', { type: 'success' }); }
      };
      if (prev) prev.onclick = () => { idx--; render(); };
    }
    document.body.appendChild(overlay);
    render();
  },

  // --- Help Overlay System ---
  help: {
    _content: '',
    _el: null,

    show(html) {
      if (LFG.help._el) LFG.help.hide();
      const content = html || LFG.help._content;
      if (!content) return;
      const overlay = document.createElement('div');
      overlay.id = 'lfg-help-overlay';
      overlay.className = 'lfg-help-overlay';
      overlay.innerHTML =
        '<div class="lfg-help-modal">' +
          '<div class="lfg-help-header">' +
            '<span class="lfg-help-title">Help</span>' +
            '<button class="lfg-help-close" onclick="LFG.help.hide()">&times;</button>' +
          '</div>' +
          '<div class="lfg-help-body">' + content + '</div>' +
        '</div>';
      overlay.addEventListener('click', function(e) {
        if (e.target === overlay) LFG.help.hide();
      });
      document.body.appendChild(overlay);
      LFG.help._el = overlay;
      requestAnimationFrame(function() { overlay.classList.add('visible'); });
    },

    hide() {
      var el = LFG.help._el;
      if (!el) return;
      el.classList.remove('visible');
      setTimeout(function() { el.remove(); }, 200);
      LFG.help._el = null;
    }
  },

  // --- Row Selection System (Splunk-style multi-select) ---
  select: {
    _state: {},

    init(tableId, opts) {
      opts = opts || {};
      var table = document.getElementById(tableId);
      if (!table) return;

      var state = { selected: new Set(), lastIdx: -1, opts: opts };
      LFG.select._state[tableId] = state;

      // Create selection toolbar
      var toolbar = document.createElement('div');
      toolbar.id = tableId + '-sel-toolbar';
      toolbar.className = 'lfg-sel-toolbar';
      toolbar.style.display = 'none';
      toolbar.innerHTML =
        '<span class="lfg-sel-count">0 selected</span>' +
        (opts.bulkActions ? opts.bulkActions.map(function(a) {
          return '<button class="lfg-sel-action" data-action="' + a.id + '">' + a.label + '</button>';
        }).join('') : '') +
        '<button class="lfg-sel-clear">Clear</button>';
      table.parentNode.insertBefore(toolbar, table);

      // Wire toolbar actions
      toolbar.querySelector('.lfg-sel-clear').onclick = function() { LFG.select.clearAll(tableId); };
      toolbar.querySelectorAll('.lfg-sel-action').forEach(function(btn) {
        btn.onclick = function() {
          var action = opts.bulkActions.find(function(a) { return a.id === btn.dataset.action; });
          if (action && action.handler) {
            var rows = LFG.select.getSelected(tableId);
            action.handler(rows);
          }
        };
      });

      // Wire row clicks
      var tbody = table.querySelector('tbody');
      if (!tbody) return;

      tbody.addEventListener('click', function(e) {
        var tr = e.target.closest('tr');
        if (!tr) return;
        var rows = Array.from(tbody.querySelectorAll('tr'));
        var idx = rows.indexOf(tr);
        if (idx < 0) return;

        if (e.metaKey || e.ctrlKey) {
          if (state.selected.has(idx)) {
            state.selected.delete(idx);
            tr.classList.remove('selected');
          } else {
            state.selected.add(idx);
            tr.classList.add('selected');
          }
        } else if (e.shiftKey && state.lastIdx >= 0) {
          var start = Math.min(state.lastIdx, idx);
          var end = Math.max(state.lastIdx, idx);
          for (var i = start; i <= end; i++) {
            state.selected.add(i);
            rows[i].classList.add('selected');
          }
        } else {
          state.selected.forEach(function(si) { rows[si] && rows[si].classList.remove('selected'); });
          state.selected.clear();
          state.selected.add(idx);
          tr.classList.add('selected');
        }
        state.lastIdx = idx;
        LFG.select._updateToolbar(tableId);
      });

      // Cmd+A to select all
      document.addEventListener('keydown', function(e) {
        if ((e.metaKey || e.ctrlKey) && e.key === 'a' && document.activeElement === document.body) {
          var rows = tbody.querySelectorAll('tr');
          if (rows.length === 0) return;
          e.preventDefault();
          rows.forEach(function(r, i) {
            state.selected.add(i);
            r.classList.add('selected');
          });
          LFG.select._updateToolbar(tableId);
        }
      });
    },

    _updateToolbar(tableId) {
      var state = LFG.select._state[tableId];
      if (!state) return;
      var toolbar = document.getElementById(tableId + '-sel-toolbar');
      if (!toolbar) return;
      var count = state.selected.size;
      toolbar.style.display = count > 0 ? 'flex' : 'none';
      var countEl = toolbar.querySelector('.lfg-sel-count');
      if (countEl) countEl.textContent = count + ' selected';
    },

    getSelected(tableId) {
      var state = LFG.select._state[tableId];
      if (!state) return [];
      var table = document.getElementById(tableId);
      if (!table) return [];
      var rows = table.querySelectorAll('tbody tr');
      var result = [];
      state.selected.forEach(function(i) { if (rows[i]) result.push(rows[i]); });
      return result;
    },

    clearAll(tableId) {
      var state = LFG.select._state[tableId];
      if (!state) return;
      var table = document.getElementById(tableId);
      if (table) table.querySelectorAll('tbody tr.selected').forEach(function(r) { r.classList.remove('selected'); });
      state.selected.clear();
      state.lastIdx = -1;
      LFG.select._updateToolbar(tableId);
    }
  },

  // --- Guided Tour System (tooltip-based walkthrough) ---
  tour: {
    _active: false,
    _steps: [],
    _idx: 0,
    _overlay: null,

    start(steps, moduleKey) {
      var storageKey = 'lfg-tour-' + (moduleKey || 'default');
      if (localStorage.getItem(storageKey)) return;
      if (!steps || steps.length === 0) return;

      LFG.tour._steps = steps;
      LFG.tour._idx = 0;
      LFG.tour._active = true;

      var overlay = document.createElement('div');
      overlay.id = 'lfg-tour-overlay';
      overlay.className = 'lfg-tour-overlay';
      document.body.appendChild(overlay);
      LFG.tour._overlay = overlay;

      LFG.tour._renderStep(storageKey);
    },

    _renderStep(storageKey) {
      var step = LFG.tour._steps[LFG.tour._idx];
      if (!step) { LFG.tour._finish(storageKey); return; }

      var target = document.querySelector(step.target);
      var overlay = LFG.tour._overlay;
      if (!overlay) return;

      var old = document.getElementById('lfg-tour-tip');
      if (old) old.remove();

      if (target) {
        var rect = target.getBoundingClientRect();
        overlay.style.clipPath = 'polygon(0% 0%, 0% 100%, ' +
          (rect.left - 8) + 'px 100%, ' +
          (rect.left - 8) + 'px ' + (rect.top - 8) + 'px, ' +
          (rect.right + 8) + 'px ' + (rect.top - 8) + 'px, ' +
          (rect.right + 8) + 'px ' + (rect.bottom + 8) + 'px, ' +
          (rect.left - 8) + 'px ' + (rect.bottom + 8) + 'px, ' +
          (rect.left - 8) + 'px 100%, 100% 100%, 100% 0%)';
      }

      var tip = document.createElement('div');
      tip.id = 'lfg-tour-tip';
      tip.className = 'lfg-tour-tip';
      tip.innerHTML =
        '<div class="lfg-tour-title">' + (step.title || '') + '</div>' +
        '<div class="lfg-tour-desc">' + (step.desc || '') + '</div>' +
        '<div class="lfg-tour-nav">' +
          '<span class="lfg-tour-progress">' + (LFG.tour._idx + 1) + '/' + LFG.tour._steps.length + '</span>' +
          '<button class="lfg-tour-skip" id="tour-skip">Skip</button>' +
          '<button class="lfg-tour-next" id="tour-next">' +
            (LFG.tour._idx < LFG.tour._steps.length - 1 ? 'Next' : 'Done') +
          '</button>' +
        '</div>';

      document.body.appendChild(tip);

      if (target) {
        var rect = target.getBoundingClientRect();
        tip.style.top = (rect.bottom + 12) + 'px';
        tip.style.left = Math.max(16, Math.min(rect.left, window.innerWidth - 300)) + 'px';
      } else {
        tip.style.top = '50%';
        tip.style.left = '50%';
        tip.style.transform = 'translate(-50%, -50%)';
      }

      tip.querySelector('#tour-next').onclick = function() {
        LFG.tour._idx++;
        if (LFG.tour._idx >= LFG.tour._steps.length) {
          LFG.tour._finish(storageKey);
        } else {
          LFG.tour._renderStep(storageKey);
        }
      };
      tip.querySelector('#tour-skip').onclick = function() {
        LFG.tour._finish(storageKey);
      };
    },

    _finish(storageKey) {
      if (storageKey) localStorage.setItem(storageKey, '1');
      LFG.tour._active = false;
      var overlay = LFG.tour._overlay;
      if (overlay) overlay.remove();
      var tip = document.getElementById('lfg-tour-tip');
      if (tip) tip.remove();
      LFG.tour._overlay = null;
    }
  },

  // --- Action Buttons ---
  createAction(label, opts = {}) {
    const btn = document.createElement('button');
    const color = opts.color || '#4a9eff';
    btn.style.cssText = LFG._btnStyle(color) + (opts.style || '');
    btn.textContent = label;
    if (opts.tip) btn.dataset.tip = opts.tip;
    if (opts.module) {
      btn.onclick = () => {
        LFG.toast(`Launching ${opts.module}...`, { type: 'info', duration: 2000 });
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lfg) {
            window.webkit.messageHandlers.lfg.postMessage({ action: 'select', module: opts.module });
          }
        } catch (err) { console.error('[LFG] postMessage failed:', err); }
      };
    }
    if (opts.onclick) btn.onclick = opts.onclick;
    return btn;
  },

  // --- Action Bar (cross-module links) ---
  createActionBar(actions) {
    const bar = document.createElement('div');
    bar.className = 'lfg-action-bar';
    bar.style.cssText = `
      display:flex; gap:8px; margin:16px 0; padding:12px 14px;
      background:#1c1c22; border-radius:8px; border:1px solid #2a2a34;
      flex-wrap:wrap; align-items:center;
    `;
    const label = document.createElement('span');
    label.style.cssText = 'font-size:10px; text-transform:uppercase; letter-spacing:0.8px; color:#6b6b78; margin-right:8px;';
    label.textContent = 'Actions';
    bar.appendChild(label);
    actions.forEach(a => bar.appendChild(LFG.createAction(a.label, a)));
    return bar;
  },

  // --- Keyboard Navigation ---
  initKeyboard(handlers) {
    document.addEventListener('keydown', e => {
      // Cmd+1..5,6,D navigate modules via rail
      if (e.metaKey && !e.shiftKey) {
        var navTarget = null;
        LFG._modules.forEach(function(m) {
          if (e.key === m.key) navTarget = m.id;
        });
        LFG._utilModules.forEach(function(m) {
          if (e.key === m.key) navTarget = m.id;
        });
        if (navTarget) {
          e.preventDefault();
          LFG._postNav('navigate', { target: navTarget });
          return;
        }
      }

      // Cmd+Shift+A = AI analyze, Cmd+Shift+S = toggle STFU badges
      if (e.metaKey && e.shiftKey && e.key === 'A') { LFG.switchSideTab('ai'); e.preventDefault(); }
      if (e.metaKey && e.shiftKey && e.key === 'S') {
        document.querySelectorAll('.stfu-badge').forEach(b => b.classList.toggle('hidden'));
        e.preventDefault();
      }

      // Escape to close help, onboarding, tour, notifications
      if (e.key === 'Escape') {
        var notifPanel = document.getElementById('lfg-notif-panel');
        if (notifPanel) { notifPanel.remove(); return; }
        if (LFG.help._el) { LFG.help.hide(); return; }
        if (LFG.tour._active) { LFG.tour._finish(); return; }
        const ob = document.getElementById('lfg-onboarding');
        if (ob) { localStorage.setItem('lfg-onboarded', '1'); ob.remove(); }
      }
      // ? key opens help
      if (e.key === '?' && !e.metaKey && !e.ctrlKey && document.activeElement === document.body) {
        LFG.help.show();
        e.preventDefault();
      }
      // Custom handlers
      if (handlers && handlers[e.key]) handlers[e.key](e);
    });
  },

  // --- Internal Helpers ---
  _btnStyle(color) {
    return `
      padding:7px 16px; border:1px solid ${color}; border-radius:6px;
      background:transparent; color:${color}; font-size:11px; font-weight:600;
      cursor:pointer; transition:all 0.15s; font-family:inherit;
      outline:none;
    `.replace(/\n\s*/g, ' ');
  },

  // --- Command Panel (module-specific actions) ---
  createCommandPanel(title, commands) {
    const panel = document.createElement('div');
    panel.className = 'lfg-command-panel';
    panel.style.cssText = `
      margin:16px 0; padding:14px 16px; background:#1c1c22; border-radius:8px;
      border:1px solid #2a2a34;
    `;
    const hdr = document.createElement('div');
    hdr.style.cssText = 'font-size:10px; text-transform:uppercase; letter-spacing:0.8px; color:#6b6b78; margin-bottom:10px;';
    hdr.textContent = title;
    panel.appendChild(hdr);

    const grid = document.createElement('div');
    grid.style.cssText = 'display:grid; grid-template-columns:repeat(auto-fill, minmax(180px, 1fr)); gap:8px;';

    commands.forEach(cmd => {
      const btn = document.createElement('button');
      const color = cmd.color || '#4a9eff';
      btn.style.cssText = `
        padding:10px 14px; border:1px solid ${color}33; border-radius:6px;
        background:${color}0a; color:#e0e0e6; font-size:11px;
        cursor:pointer; transition:all 0.15s; font-family:inherit;
        text-align:left; outline:none; display:flex; flex-direction:column; gap:3px;
      `.replace(/\n\s*/g, ' ');
      btn.innerHTML = `
        <span style="font-weight:600;color:${color}">${cmd.label}</span>
        ${cmd.desc ? '<span style="font-size:10px;color:#6b6b78">' + cmd.desc + '</span>' : ''}
        ${cmd.cli ? '<code style="font-size:9px;color:#4a4a56;margin-top:2px">' + cmd.cli + '</code>' : ''}
      `;
      btn.onmouseenter = () => { btn.style.borderColor = color; btn.style.background = color + '15'; };
      btn.onmouseleave = () => { btn.style.borderColor = color + '33'; btn.style.background = color + '0a'; };

      if (cmd.module) {
        btn.onclick = () => {
          LFG.toast('Running: ' + (cmd.cli || cmd.label), { type: 'info', duration: 2500 });
          try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lfg) {
              window.webkit.messageHandlers.lfg.postMessage({
                action: cmd.action || 'run',
                module: cmd.module,
                args: cmd.args || ''
              });
            }
          } catch (err) { console.error('[LFG] postMessage failed:', err); }
        };
      }
      if (cmd.onclick) btn.onclick = cmd.onclick;
      if (cmd.tip) btn.dataset.tip = cmd.tip;
      grid.appendChild(btn);
    });

    panel.appendChild(grid);
    return panel;
  },

  // --- Exec Bridge (run shell commands from JS, get results back) ---

  _execCallbacks: {},
  _execCounter: 0,

  exec(cmd, callback) {
    const id = 'exec_' + (++LFG._execCounter);
    LFG._execCallbacks[id] = callback || function(){};
    LFG._postNav('exec', { cmd: cmd, id: id });
  },

  confirm(message, cmd, callback) {
    const id = 'exec_' + (++LFG._execCounter);
    LFG._execCallbacks[id] = callback || function(){};
    LFG._postNav('confirm', { message: message, cmd: cmd, id: id });
  },

  _onExecResult(id, stdout, stderr, exitCode) {
    const cb = LFG._execCallbacks[id];
    if (cb) {
      delete LFG._execCallbacks[id];
      cb(stdout, stderr, exitCode);
    }
  },

  actionButton(label, opts = {}) {
    const btn = document.createElement('button');
    const color = opts.color || '#4a9eff';
    btn.style.cssText = LFG._btnStyle(color);
    btn.textContent = label;
    if (opts.tip) btn.dataset.tip = opts.tip;

    btn.onclick = () => {
      const origText = btn.textContent;
      btn.textContent = 'Running...';
      btn.disabled = true;
      btn.style.opacity = '0.6';

      const done = (stdout, stderr, code) => {
        btn.textContent = origText;
        btn.disabled = false;
        btn.style.opacity = '1';
        if (code === 0) {
          LFG.toast(opts.successMsg || label + ' completed', { type: 'success' });
          if (opts.onSuccess) opts.onSuccess(stdout);
        } else if (code === -1) {
          LFG.toast('Cancelled', { type: 'warning', duration: 1500 });
        } else {
          LFG.toast(stderr || label + ' failed', { type: 'error' });
          if (opts.onError) opts.onError(stderr, code);
        }
        if (opts.refresh) LFG.refreshView();
      };

      if (opts.confirm) {
        LFG.confirm(opts.confirm, opts.cmd, done);
      } else {
        LFG.exec(opts.cmd, done);
      }
    };
    return btn;
  },

  refreshView() {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lfg) {
      const currentPath = window.location.pathname;
      const match = currentPath.match(/\.lfg_(\w+)\.html/);
      if (match) {
        LFG._postNav('navigate', { target: match[1] });
      } else {
        window.location.reload();
      }
    } else {
      window.location.reload();
    }
  },

  // --- Navigation Helpers ---

  _postNav(action, extra) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lfg) {
        var msg = { action: action };
        if (extra) for (var k in extra) msg[k] = extra[k];
        window.webkit.messageHandlers.lfg.postMessage(msg);
      }
    } catch (err) { console.error('[LFG] _postNav failed:', err); }
  },

  // --- Omnipresent Icon Rail Shell ---
  _injectShell(opts) {
    var mod = opts.module || '';

    // Shield logo SVG
    var logoSvg = '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="#4a9eff" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><text x="12" y="15" text-anchor="middle" fill="#4a9eff" stroke="none" font-size="8" font-weight="800" font-family="system-ui">F</text></svg>';

    // Bell icon SVG
    var bellSvg = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M18 8A6 6 0 006 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 01-3.46 0"/></svg>';

    // Help icon
    var helpSvg = '?';

    // Gear icon SVG
    var gearSvg = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 01-2.83 2.83l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-4 0v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 01-2.83-2.83l.06-.06A1.65 1.65 0 004.68 15a1.65 1.65 0 00-1.51-1H3a2 2 0 010-4h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 012.83-2.83l.06.06A1.65 1.65 0 009 4.68a1.65 1.65 0 001-1.51V3a2 2 0 014 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 012.83 2.83l-.06.06A1.65 1.65 0 0019.4 9a1.65 1.65 0 001.51 1H21a2 2 0 010 4h-.09a1.65 1.65 0 00-1.51 1z"/></svg>';

    // Build rail HTML
    var html = '<div class="rail-logo" onclick="LFG._postNav(\'home\')" data-tip="Home">' + logoSvg + '</div>';

    // Module icons
    LFG._modules.forEach(function(m) {
      var active = (m.id === mod) ? ' active' : '';
      var svgStr = m.icon.replace(/stroke="[^"]*"/g, '').replace(/<svg /, '<svg stroke="currentColor" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" ');
      html += '<a class="rail-item' + active + '" onclick="LFG._postNav(\'navigate\',{target:\'' + m.id + '\'})" data-tip="' + m.label + ' (\u2318' + m.key.toUpperCase() + ')">' + svgStr + '</a>';
    });

    html += '<div class="rail-sep"></div>';

    // Utility modules (Chat, Dash)
    LFG._utilModules.forEach(function(m) {
      var active = (m.id === mod) ? ' active' : '';
      var svgStr = m.icon.replace(/stroke="[^"]*"/g, '').replace(/<svg /, '<svg stroke="currentColor" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" ');
      html += '<a class="rail-item' + active + '" onclick="LFG._postNav(\'navigate\',{target:\'' + m.id + '\'})" data-tip="' + m.label + ' (\u2318' + m.key.toUpperCase() + ')">' + svgStr + '</a>';
    });

    html += '<div class="rail-spacer"></div>';

    // Bell / notifications
    html += '<a class="rail-item rail-bell" onclick="LFG.notifications._toggle()" data-tip="Notifications">' + bellSvg + '<span class="rail-badge" id="lfg-notif-badge">0</span></a>';

    html += '<div class="rail-sep"></div>';

    // Help + Settings
    html += '<a class="rail-item rail-help" onclick="LFG.help.show()" data-tip="Help (?)">' + helpSvg + '</a>';
    html += '<a class="rail-item" onclick="LFG._postNav(\'navigate\',{target:\'settings\'})" data-tip="Settings">' + gearSvg + '</a>';

    // Create rail element
    var rail = document.createElement('nav');
    rail.className = 'lfg-rail';
    rail.innerHTML = html;

    // Wrap existing body children into .lfg-main
    var main = document.createElement('div');
    main.className = 'lfg-main';
    while (document.body.firstChild) {
      main.appendChild(document.body.firstChild);
    }

    document.body.classList.add('lfg-shell');
    document.body.appendChild(rail);
    document.body.appendChild(main);

    // Init notifications badge
    LFG.notifications._load();
    LFG.notifications._badge = document.getElementById('lfg-notif-badge');
    LFG.notifications._updateBadge();
  },

  // --- Thin Context Bar (inside .lfg-main) ---
  _injectHeader(opts) {
    var mod = opts.module || '';
    var ctx = opts.context || '';
    var modVer = opts.moduleVersion || '1.0.0';

    var hdr = document.createElement('div');
    hdr.id = 'lfg-sticky-header';

    var html = '';
    if (mod) html += '<span class="sh-module">' + mod.toUpperCase() + '</span>';
    if (ctx) html += '<span class="sh-context">' + ctx + '</span>';
    html += '<span class="sh-spacer"></span>';
    html += '<span class="sh-version">v' + modVer + '</span>';

    hdr.innerHTML = html;

    // Insert at top of .lfg-main if shell is injected, otherwise body
    var target = document.querySelector('.lfg-main');
    if (target) {
      target.insertBefore(hdr, target.firstChild);
    } else {
      document.body.prepend(hdr);
    }
  },

  // --- Sticky Footer ---
  _injectFooter(opts) {
    const modVer = opts.moduleVersion || '1.0.0';
    const payUrl = 'https://www.paypal.com/cgi-bin/webscr?cmd=_xclick&business=jeremiah%403vs.io&amount=5&currency_code=USD&item_name=Coffee%20for%20LFG%20Developer';

    const ftr = document.createElement('div');
    ftr.id = 'lfg-sticky-footer';
    ftr.innerHTML =
      '<span class="sf-item">' + (opts.module ? opts.module.toUpperCase() + ' v' + modVer : 'LFG') + '</span>' +
      '<span class="sf-sep">|</span>' +
      '<span class="sf-item">LFG Platform v' + LFG.version + '</span>' +
      '<span class="sf-sep">|</span>' +
      '<span class="sf-item">YJ Tools Ecosystem</span>' +
      '<span class="sf-sep">|</span>' +
      '<span class="sf-item">&copy; 2024&ndash;2026 MIT License</span>' +
      '<span class="sf-sep">|</span>' +
      '<span class="sf-item">Made with <span class="sf-heart">&hearts;</span> in NYC</span>' +
      '<span class="sf-sep">|</span>' +
      '<span class="sf-item"><a href="' + payUrl + '" target="_blank">Buy me a coffee!</a></span>';

    // Append to .lfg-main if shell is present
    var target = document.querySelector('.lfg-main') || document.body;
    target.appendChild(ftr);
  },

  // --- Side Panel Tabs (Two-Column Layout) ---
  switchSideTab(name) {
    document.querySelectorAll('.side-panel').forEach(p => p.classList.remove('active'));
    document.querySelectorAll('.side-tab-nav a').forEach(a => a.classList.remove('active'));
    const panel = document.getElementById('side-' + name);
    if (panel) panel.classList.add('active');
    document.querySelectorAll('.side-tab-nav a').forEach(a => {
      if (a.dataset.tab === name) a.classList.add('active');
    });
    LFG.toast('Side: ' + name.toUpperCase(), { type: 'info', duration: 1200 });
  },

  // --- AI Namespace ---
  ai: {
    analyze(path, cb) {
      LFG.exec('~/tools/@yj/lfg/lfg ai analyze ' + path, (out, err, code) => {
        if (code === 0) { try { cb(JSON.parse(out)); } catch(e) { cb({ error: 'parse', raw: out }); } }
        else cb({ error: err || 'AI unavailable' });
      });
    },
    compare(a, b, cb) {
      LFG.exec('~/tools/@yj/lfg/lfg ai compare ' + a + ' ' + b, (out, err, code) => {
        if (code === 0) { try { cb(JSON.parse(out)); } catch(e) { cb({ error: 'parse', raw: out }); } }
        else cb({ error: err || 'AI unavailable' });
      });
    },
    suggest(path, cb) {
      LFG.exec('~/tools/@yj/lfg/lfg ai suggest ' + path, (out, err, code) => {
        if (code === 0) { try { cb(JSON.parse(out)); } catch(e) { cb({ error: 'parse', raw: out }); } }
        else cb({ error: err || 'AI unavailable' });
      });
    },
    isAvailable(cb) {
      LFG.exec('~/tools/@yj/lfg/lfg ai config get endpoint', (out, err, code) => {
        cb(code === 0 && out.trim().length > 0);
      });
    },
    batchAnalyze(paths, progressCb) {
      let done = 0;
      paths.forEach(p => {
        LFG.ai.analyze(p, result => {
          done++;
          if (progressCb) progressCb(p, result, done, paths.length);
        });
      });
    }
  },

  // --- Chat Namespace (Dashboard Side Panel) ---
  chat: {
    _convId: null,
    _serverUrl: 'http://localhost:3033',
    _agentColors: {
      router: '#4a9eff', wtfs: '#4a9eff', dtf: '#ff8c42',
      btau: '#06d6a0', devdrive: '#c084fc', stfu: '#e879f9'
    },

    initPanel(containerId) {
      var el = document.getElementById(containerId);
      if (!el) return;
      el.innerHTML = '';
      var _t = document.createElement('div'); _t.className = 'section-title'; _t.textContent = 'AI Chat'; el.appendChild(_t);
      var _ch = document.createElement('div'); _ch.className = 'chat-panel-chips';
      [['Top space','What is using the most space?'],['Clean caches','Clean safe caches'],['Backups','Backup status']].forEach(function(c) {
        var b = document.createElement('button'); b.className = 'chat-panel-chip'; b.textContent = c[0];
        b.onclick = function() { LFG.chat.send(c[1]); }; _ch.appendChild(b);
      });
      el.appendChild(_ch);
      var _msgs = document.createElement('div'); _msgs.id = 'chat-panel-msgs'; _msgs.className = 'chat-panel-messages'; el.appendChild(_msgs);
      var _iw = document.createElement('div'); _iw.className = 'chat-panel-input';
      var _inp = document.createElement('input'); _inp.id = 'chat-panel-input'; _inp.placeholder = 'Ask LFG...';
      _inp.onkeydown = function(e) { if (e.key === 'Enter') LFG.chat.send(); };
      var _sb = document.createElement('button'); _sb.textContent = 'Send'; _sb.onclick = function() { LFG.chat.send(); };
      _iw.appendChild(_inp); _iw.appendChild(_sb); el.appendChild(_iw);
    },

    send(text) {
      var input = document.getElementById('chat-panel-input');
      var message = text || (input ? input.value.trim() : '');
      if (!message) return;
      if (input) input.value = '';

      LFG.chat._addBubble('user', message);

      fetch(LFG.chat._serverUrl + '/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          message: message,
          conversation_id: LFG.chat._convId
        })
      }).then(function(r) { return r.json(); }).then(function(data) {
        LFG.chat._convId = data.conversation_id;
        LFG.chat._addBubble('assistant', data.response, data.agent);
      }).catch(function() {
        LFG.chat._addBubble('assistant', 'Chat server offline. Start: python3 lib/chat_server.py &', 'router');
      });
    },

    _addBubble(role, content, agent) {
      var msgs = document.getElementById('chat-panel-msgs');
      if (!msgs) return;
      var bubble = document.createElement('div');
      bubble.className = 'chat-bubble ' + role;
      var html = '';
      if (role === 'assistant' && agent) {
        var color = LFG.chat._agentColors[agent] || '#4a9eff';
        html += '<div class="cb-agent" style="color:' + color + '">' + agent.toUpperCase() + '</div>';
      }
      html += content
        .replace(/```(\w*)\n([\s\S]*?)```/g, '<pre style="background:#0d0d10;border:1px solid #2a2a34;border-radius:4px;padding:6px 8px;font-size:10px;overflow-x:auto;margin:4px 0"><code>$2</code></pre>')
        .replace(/`([^`]+)`/g, '<code style="background:#2a2a34;padding:1px 4px;border-radius:3px;font-size:10px;color:#4a9eff">$1</code>')
        .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
        .replace(/\n/g, '<br>');
      bubble.innerHTML = html;
      msgs.appendChild(bubble);
      msgs.scrollTop = msgs.scrollHeight;
    },

    isAvailable(cb) {
      fetch(LFG.chat._serverUrl + '/health', { method: 'GET' })
        .then(function(r) { return r.json(); })
        .then(function(d) { cb(true, d); })
        .catch(function() { cb(false); });
    }
  },

  // --- Settings Persistence ---
  settings: {
    get(key) { try { return JSON.parse(localStorage.getItem('lfg-settings') || '{}')[key]; } catch(e) { return undefined; } },
    set(key, val) {
      try {
        const s = JSON.parse(localStorage.getItem('lfg-settings') || '{}');
        s[key] = val;
        localStorage.setItem('lfg-settings', JSON.stringify(s));
      } catch(e) {}
    }
  },

  // --- Init All Systems ---
  init(opts = {}) {
    LFG.initTooltips();
    if (opts.keyboard !== false) LFG.initKeyboard(opts.keyHandlers);
    if (opts.onboarding) LFG.showOnboarding(opts.onboarding);
    if (opts.welcome) setTimeout(() => LFG.toast(opts.welcome, { type: 'info' }), 600);

    // Store help content for ? button
    if (opts.helpContent) LFG.help._content = opts.helpContent;

    // Inject shell (rail + main wrapper), then header/footer inside main
    if (opts.stickyChrome !== false) {
      LFG._injectShell(opts);
      LFG._injectHeader(opts);
      LFG._injectFooter(opts);
    }

    // Tour auto-start
    if (opts.tour) {
      setTimeout(function() { LFG.tour.start(opts.tour, opts.module || 'default'); }, 800);
    }

    // Inject global animation keyframe
    const style = document.createElement('style');
    style.textContent = '@keyframes lfgFadeIn { from { opacity:0; transform:scale(0.95); } to { opacity:1; transform:scale(1); } }';
    document.head.appendChild(style);

    // Restore saved theme preference
    LFG.theme.restore();
  }
};

// =============================================================================
// LFG.theme - Theme variant management
// Themes: default, compact, glass, high-contrast
// Persisted to localStorage key 'lfg-theme'
// =============================================================================
LFG.theme = (() => {
  const THEMES = ['default', 'compact', 'glass', 'high-contrast'];
  const STORE_KEY = 'lfg-theme';

  function _clearClasses() {
    THEMES.forEach(t => {
      if (t !== 'default') document.body.classList.remove('theme-' + t);
    });
  }

  function set(name) {
    if (!THEMES.includes(name)) return;
    _clearClasses();
    if (name !== 'default') document.body.classList.add('theme-' + name);
    try { localStorage.setItem(STORE_KEY, name); } catch (_) {}
  }

  function get() {
    try {
      var saved = localStorage.getItem(STORE_KEY);
      return (saved && THEMES.includes(saved)) ? saved : 'default';
    } catch (_) { return 'default'; }
  }

  function toggle() {
    var cur = get();
    var idx = THEMES.indexOf(cur);
    var next = THEMES[(idx + 1) % THEMES.length];
    set(next);
    LFG.toast('Theme: ' + next, { type: 'info', duration: 2000 });
  }

  function restore() {
    var saved = get();
    if (saved !== 'default') set(saved);
  }

  return { THEMES, set, get, toggle, restore };
})();
