// =============================================================================
// LFG UI Module - Shared JavaScript for all LFG views
// Provides: toasters, tooltips, getting started, cross-module actions, kbd nav
// =============================================================================

const LFG = {
  version: '1.0.0',

  // --- Toaster Notification System ---
  toast: (() => {
    let container = null;
    function ensureContainer() {
      if (container) return container;
      container = document.createElement('div');
      container.id = 'lfg-toaster';
      container.style.cssText = `
        position:fixed; bottom:16px; right:16px; z-index:9999;
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

  // --- Getting Started Showcase ---
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
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lfg) {
          window.webkit.messageHandlers.lfg.postMessage({ action: 'select', module: opts.module });
        }
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
      // Cmd+1/2/3 for tabs
      if (e.metaKey && e.key >= '1' && e.key <= '9') {
        const idx = parseInt(e.key) - 1;
        const tabs = document.querySelectorAll('.nav a');
        if (tabs[idx]) { tabs[idx].click(); e.preventDefault(); }
      }
      // Escape to close onboarding
      if (e.key === 'Escape') {
        const ob = document.getElementById('lfg-onboarding');
        if (ob) { localStorage.setItem('lfg-onboarded', '1'); ob.remove(); }
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

  // --- Init All Systems ---
  init(opts = {}) {
    LFG.initTooltips();
    if (opts.keyboard !== false) LFG.initKeyboard(opts.keyHandlers);
    if (opts.onboarding) LFG.showOnboarding(opts.onboarding);
    if (opts.welcome) setTimeout(() => LFG.toast(opts.welcome, { type: 'info' }), 600);

    // Inject global animation keyframe
    const style = document.createElement('style');
    style.textContent = '@keyframes lfgFadeIn { from { opacity:0; transform:scale(0.95); } to { opacity:1; transform:scale(1); } }';
    document.head.appendChild(style);
  }
};
