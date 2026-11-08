'use strict';

const STORAGE_KEY = 'trackpulseAdminToken';
const toast = document.querySelector('#toast');
let adminToken = sessionStorage.getItem(STORAGE_KEY) || '';
let apiToken = '';
let infoCache = null;
let themeState = null;
let toastTimer = null;

function showToast(message) {
  toast.textContent = message;
  toast.hidden = false;
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { toast.hidden = true; }, 2600);
}

function colorToHex(value) {
  const raw = String(value || '').trim();
  if (/^#[0-9a-fA-F]{6}$/.test(raw)) return raw;
  if (/^#[0-9a-fA-F]{3}$/.test(raw)) {
    return `#${raw[1]}${raw[1]}${raw[2]}${raw[2]}${raw[3]}${raw[3]}`;
  }
  return '#f4d21f';
}

async function ensureApiToken() {
  if (apiToken) return apiToken;
  const response = await fetch(`/api/local-token?t=${Date.now()}`, { cache: 'no-store' });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || !data.token) throw new Error(data.error || 'Нет API-токена');
  apiToken = String(data.token);
  return apiToken;
}

async function request(url, options = {}, useAdmin = false) {
  const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) };
  headers['X-TrackPulse-Token'] = await ensureApiToken();
  if (useAdmin) headers['X-TrackPulse-Admin'] = adminToken;
  const response = await fetch(url, { cache: 'no-store', ...options, headers });
  const data = await response.json().catch(() => ({}));
  if (response.status === 401 && useAdmin) {
    sessionStorage.removeItem(STORAGE_KEY);
    location.href = 'stats.html';
    throw new Error('Сессия админки истекла');
  }
  if (!response.ok || data.ok === false) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

function fillThemeForm(theme) {
  themeState = theme;
  const vars = theme.cssVars || {};
  const cfg = theme.config || {};
  document.querySelector('#var-widget-width').value = vars['widget-width'] || '760px';
  document.querySelector('#var-widget-height').value = vars['widget-height'] || '132px';
  document.querySelector('#var-radius').value = vars.radius || '22px';
  document.querySelector('#var-surface').value = colorToHex(vars.surface || '#0f1013');
  document.querySelector('#var-accent').value = colorToHex(vars.accent || '#f4d21f');
  document.querySelector('#var-primary').value = colorToHex(vars.primary || '#f7f7f8');
  document.querySelector('#var-secondary').value = colorToHex(vars.secondary || '#a6a8af');
  document.querySelector('#var-muted').value = colorToHex(vars.muted || '#767981');
  document.querySelector('#var-title-size').value = vars['title-size'] || '25px';
  document.querySelector('#var-artist-size').value = vars['artist-size'] || '15px';
  document.querySelector('#cfg-visibleDurationMs').value = cfg.visibleDurationMs ?? 7000;
  document.querySelector('#cfg-scrollSpeedPxPerSecond').value = cfg.scrollSpeedPxPerSecond ?? 42;
  document.querySelector('#cfg-showSourceLabel').checked = cfg.showSourceLabel !== false;
  document.querySelector('#cfg-hideWhenPaused').checked = Boolean(cfg.hideWhenPaused);
}

function readThemeForm() {
  const prev = themeState || { cssVars: {}, config: {} };
  return {
    version: 1,
    cssVars: {
      ...(prev.cssVars || {}),
      'widget-width': document.querySelector('#var-widget-width').value.trim() || '760px',
      'widget-height': document.querySelector('#var-widget-height').value.trim() || '132px',
      radius: document.querySelector('#var-radius').value.trim() || '22px',
      surface: document.querySelector('#var-surface').value,
      accent: document.querySelector('#var-accent').value,
      primary: document.querySelector('#var-primary').value,
      secondary: document.querySelector('#var-secondary').value,
      muted: document.querySelector('#var-muted').value,
      'title-size': document.querySelector('#var-title-size').value.trim() || '25px',
      'artist-size': document.querySelector('#var-artist-size').value.trim() || '15px'
    },
    config: {
      ...(prev.config || {}),
      visibleDurationMs: Number(document.querySelector('#cfg-visibleDurationMs').value) || 7000,
      scrollSpeedPxPerSecond: Number(document.querySelector('#cfg-scrollSpeedPxPerSecond').value) || 42,
      showSourceLabel: document.querySelector('#cfg-showSourceLabel').checked,
      hideWhenPaused: document.querySelector('#cfg-hideWhenPaused').checked
    }
  };
}

function renderInfo(info) {
  infoCache = info;
  const paths = info.paths || {};
  const modeLabel = document.querySelector('#runtimeModeLabel');
  const pathJournal = document.querySelector('#pathJournal');
  const pathHistory = document.querySelector('#pathHistory');
  if (modeLabel) {
    modeLabel.textContent = info.daemonMode ? 'постоянная запись (daemon)' : 'обычный';
  }
  if (pathJournal && paths.journal) pathJournal.textContent = paths.journal;
  if (pathHistory && paths.history) pathHistory.textContent = paths.history;

  document.querySelector('#infoBox').textContent = [
    `Версия: ${info.version}`,
    `Порт: ${info.port}`,
    `Daemon: ${info.daemonMode ? 'да (эфир всегда)' : 'нет'}`,
    `Сессия эфира: ${info.sessionActive ? 'активна' : 'нет'}`,
    `Треков в журнале: ${info.journalTracks}`,
    `API token: ${info.apiToken}`,
    '',
    `project: ${paths.project}`,
    `theme: ${paths.theme}`,
    `settings: ${paths.settings}`,
    `apiTokenFile: ${paths.apiTokenFile}`,
    `adminPasswordHash: ${paths.adminPasswordHash}`,
    `logs: ${paths.logs}`
  ].join('\n');
}

function renderSources(sources) {
  if (!sources?.length) {
    document.querySelector('#sourcesBox').textContent = 'Нет активных вкладок с треками';
    return;
  }
  document.querySelector('#sourcesBox').textContent = sources.map((item) => {
    const play = item.isPlaying ? '▶' : '⏸';
    return `${play} [${item.providerLabel || item.provider}] ${item.artist || '—'} — ${item.title || '—'}`;
  }).join('\n');
}

async function loadAll() {
  const [info, theme, settings] = await Promise.all([
    request('/api/admin/info', {}, true),
    request('/api/theme'),
    request('/api/settings')
  ]);
  renderInfo(info);
  renderSources(info.sources || []);
  fillThemeForm(theme.theme);
  document.querySelector('#preferredProvider').value = settings.settings?.preferredProvider || 'auto';
}

async function boot() {
  if (!adminToken) {
    location.href = 'stats.html';
    return;
  }
  try {
    await loadAll();
  } catch (error) {
    showToast(error.message);
    setTimeout(() => { location.href = 'stats.html'; }, 1200);
  }
}

document.querySelector('#logoutButton').addEventListener('click', () => {
  sessionStorage.removeItem(STORAGE_KEY);
  location.href = 'stats.html';
});

document.querySelector('#refreshInfo').addEventListener('click', async () => {
  try {
    const info = await request('/api/admin/info', {}, true);
    renderInfo(info);
    renderSources(info.sources || []);
    showToast('Обновлено');
  } catch (error) {
    showToast(error.message);
  }
});

document.querySelector('#copyToken').addEventListener('click', async () => {
  if (!infoCache?.apiToken) return;
  await navigator.clipboard.writeText(infoCache.apiToken);
  showToast('API-токен скопирован');
});

document.querySelector('#sendTest').addEventListener('click', async () => {
  try {
    await request('/api/admin/test-track', {
      method: 'POST',
      body: JSON.stringify({
        provider: document.querySelector('#testProvider').value,
        artist: document.querySelector('#testArtist').value,
        title: document.querySelector('#testTitle').value,
        duration: 210,
        position: 18
      })
    }, true);
    document.querySelector('#preview').src = `/?t=${Date.now()}`;
    showToast('Тестовый трек отправлен в оверлей');
  } catch (error) {
    showToast(error.message);
  }
});

document.querySelector('#clearOverlay').addEventListener('click', async () => {
  try {
    await request('/api/admin/clear-overlay', { method: 'POST', body: '{}' }, true);
    showToast('Оверлей очищен');
  } catch (error) {
    showToast(error.message);
  }
});

document.querySelector('#changePassword').addEventListener('click', async () => {
  try {
    await request('/api/admin/password', {
      method: 'POST',
      body: JSON.stringify({
        currentPassword: document.querySelector('#currentPassword').value,
        newPassword: document.querySelector('#newPassword').value
      })
    }, true);
    document.querySelector('#currentPassword').value = '';
    document.querySelector('#newPassword').value = '';
    showToast('Пароль админки обновлён');
  } catch (error) {
    showToast(error.message);
  }
});

document.querySelector('#saveSettings').addEventListener('click', async () => {
  try {
    await request('/api/admin/settings', {
      method: 'POST',
      body: JSON.stringify({
        settings: { preferredProvider: document.querySelector('#preferredProvider').value }
      })
    }, true);
    showToast('Приоритет источника сохранён');
  } catch (error) {
    showToast(error.message);
  }
});

document.querySelector('#saveTheme').addEventListener('click', async () => {
  try {
    const theme = readThemeForm();
    const data = await request('/api/admin/theme', {
      method: 'POST',
      body: JSON.stringify({ theme })
    }, true);
    fillThemeForm(data.theme);
    document.querySelector('#preview').src = `/?t=${Date.now()}`;
    showToast('Стили сохранены');
  } catch (error) {
    showToast(error.message);
  }
});

document.querySelector('#reloadPreview').addEventListener('click', () => {
  document.querySelector('#preview').src = `/?t=${Date.now()}`;
});

for (const button of document.querySelectorAll('.preset')) {
  button.addEventListener('click', async () => {
    try {
      const data = await request('/api/admin/theme', {
        method: 'POST',
        body: JSON.stringify({ preset: button.dataset.preset })
      }, true);
      fillThemeForm(data.theme);
      document.querySelector('#preview').src = `/?t=${Date.now()}`;
      showToast(`Пресет ${button.dataset.preset}`);
    } catch (error) {
      showToast(error.message);
    }
  });
}

setInterval(async () => {
  try {
    const info = await request('/api/admin/info', {}, true);
    renderSources(info.sources || []);
  } catch {
    // ignore polling errors
  }
}, 2500);

boot();
