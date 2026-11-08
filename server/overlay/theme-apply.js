'use strict';

(function initThemeApply() {
  function hexToRgba(hex, alpha) {
    const raw = String(hex || '').trim();
    const short = raw.match(/^#([0-9a-fA-F]{3})$/);
    const full = raw.match(/^#([0-9a-fA-F]{6})$/);
    let r = 244;
    let g = 210;
    let b = 31;
    if (full) {
      r = parseInt(full[1].slice(0, 2), 16);
      g = parseInt(full[1].slice(2, 4), 16);
      b = parseInt(full[1].slice(4, 6), 16);
    } else if (short) {
      r = parseInt(short[1][0] + short[1][0], 16);
      g = parseInt(short[1][1] + short[1][1], 16);
      b = parseInt(short[1][2] + short[1][2], 16);
    }
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
  }

  function applyThemePayload(theme) {
    if (!theme || typeof theme !== 'object') return;
    const vars = theme.cssVars || {};
    const root = document.documentElement;
    for (const [key, value] of Object.entries(vars)) {
      if (value === undefined || value === null || value === '') continue;
      root.style.setProperty(`--${key}`, String(value));
    }

    const accent = String(vars.accent || getComputedStyle(root).getPropertyValue('--accent') || '#f4d21f').trim();
    const surface = String(vars.surface || getComputedStyle(root).getPropertyValue('--surface') || '#131419').trim();
    const primary = String(vars.primary || getComputedStyle(root).getPropertyValue('--primary') || '#f7f7f8').trim();
    const secondary = String(vars.secondary || getComputedStyle(root).getPropertyValue('--secondary') || '#a6a8af').trim();
    const muted = String(vars.muted || getComputedStyle(root).getPropertyValue('--muted') || '#888c96').trim();
    const radius = String(vars.radius || getComputedStyle(root).getPropertyValue('--radius') || '20px').trim();
    const font = String(vars.font || getComputedStyle(root).getPropertyValue('--font') || '').trim();

    root.style.setProperty('--accent', accent);
    root.style.setProperty('--surface', surface);
    root.style.setProperty('--text', primary);
    root.style.setProperty('--muted', muted);
    root.style.setProperty('--secondary', secondary);
    root.style.setProperty('--radius', radius);
    root.style.setProperty('--accent-soft', hexToRgba(accent, 0.12));
    root.style.setProperty('--accent-glow', hexToRgba(accent, 0.22));
    root.style.setProperty('--accent-ring', hexToRgba(accent, 0.45));
    if (font) root.style.setProperty('--font', font);

    document.body.style.background = `radial-gradient(circle at 12% 0%, ${hexToRgba(accent, 0.1)}, transparent 28%), #0b0c0e`;
  }

  async function loadSharedTheme() {
    try {
      const response = await fetch(`/api/theme?t=${Date.now()}`, { cache: 'no-store' });
      if (!response.ok) return;
      const data = await response.json();
      applyThemePayload(data.theme);
    } catch {
      // keep CSS defaults
    }
  }

  window.TrackPulseTheme = { applyThemePayload, loadSharedTheme };
  loadSharedTheme();
  setInterval(() => loadSharedTheme().catch(() => {}), 4000);
})();
