'use strict';

const SERVER_BASE = 'http://127.0.0.1:18181';
const tabStates = new Map();
const ALLOWED_PROVIDERS = new Set(['yandex', 'vk']);

let lastPostedFingerprint = '';
let lastPostAt = 0;
let apiToken = '';
let stickyProvider = '';
let lastNonEmptyState = null;
let lastNonEmptyAt = 0;
let holdEmptyTimer = null;
let settings = {
  preferredProvider: 'auto',
  holdLastTrackMs: 2800,
  stalePlayingMs: 8000,
  stalePausedMs: 60000
};

function providerLabel(provider) {
  if (provider === 'vk') return 'VK';
  if (provider === 'yandex') return 'Яндекс Музыка';
  return 'Неизвестно';
}

function normalizeState(state, tabId) {
  const provider = ALLOWED_PROVIDERS.has(state.provider) ? state.provider : 'unknown';
  const artwork = String(state.artwork || '');
  return {
    source: 'trackpulse-extension',
    provider,
    providerLabel: providerLabel(provider),
    tabId,
    title: String(state.title || '').trim().slice(0, 500),
    artist: String(state.artist || '').trim().slice(0, 500),
    album: String(state.album || '').trim().slice(0, 500),
    artwork: /^https:\/\//i.test(artwork) ? artwork.slice(0, 3000) : '',
    duration: Number.isFinite(Number(state.duration)) ? Math.max(0, Number(state.duration)) : 0,
    position: Number.isFinite(Number(state.position)) ? Math.max(0, Number(state.position)) : 0,
    positionSource: String(state.positionSource || '').slice(0, 100),
    level: Math.max(0, Math.min(1, Number(state.level) || 0)),
    levelSource: String(state.levelSource || '').slice(0, 40),
    isPlaying: Boolean(state.isPlaying),
    hasTrack: Boolean(state.hasTrack),
    revision: Math.max(0, Number(state.revision) || 0),
    capturedAt: Number(state.capturedAt) || Date.now(),
    receivedAt: Date.now()
  };
}

function emptyState(now = Date.now()) {
  return {
    source: 'trackpulse-extension',
    provider: '',
    providerLabel: '',
      title: '', artist: '', album: '', artwork: '',
      duration: 0, position: 0, positionSource: '',
      level: 0, levelSource: '',
      isPlaying: false, hasTrack: false, revision: 0,
      capturedAt: now, receivedAt: now
    };
  }

function pruneTabStates(now) {
  for (const [tabId, state] of tabStates.entries()) {
    const staleAfter = state.isPlaying
      ? Number(settings.stalePlayingMs) || 8000
      : Number(settings.stalePausedMs) || 60000;
    if (now - state.receivedAt > staleAfter) tabStates.delete(tabId);
  }
}

function chooseState() {
  const now = Date.now();
  pruneTabStates(now);

  const states = [...tabStates.values()].filter((state) => state.hasTrack && ALLOWED_PROVIDERS.has(state.provider));
  if (!states.length) {
    const holdMs = Number(settings.holdLastTrackMs) || 2800;
    if (lastNonEmptyState && now - lastNonEmptyAt < holdMs) {
      return { ...lastNonEmptyState, isPlaying: false, receivedAt: now };
    }
    return emptyState(now);
  }

  const playing = states.filter((state) => state.isPlaying);
  const preferred = settings.preferredProvider;

  const pickNewest = (list) => [...list].sort((a, b) => b.receivedAt - a.receivedAt)[0];

  let chosen = null;
  if (playing.length) {
    if (preferred === 'yandex' || preferred === 'vk') {
      chosen = playing.find((state) => state.provider === preferred) || pickNewest(playing);
    } else if (stickyProvider) {
      chosen = playing.find((state) => state.provider === stickyProvider) || pickNewest(playing);
    } else {
      chosen = pickNewest(playing);
    }
    stickyProvider = chosen.provider;
  } else {
    // Ничего не играет: держимся за последний активный провайдер, чтобы VK→Яндекс не мигал пустотой.
    if (preferred === 'yandex' || preferred === 'vk') {
      chosen = states.find((state) => state.provider === preferred) || pickNewest(states);
    } else if (stickyProvider) {
      chosen = states.find((state) => state.provider === stickyProvider) || pickNewest(states);
    } else {
      chosen = pickNewest(states);
    }
  }

  lastNonEmptyState = chosen;
  lastNonEmptyAt = now;
  return chosen;
}

async function ensureApiToken() {
  if (apiToken) return apiToken;
  const stored = await chrome.storage.local.get(['apiToken']);
  if (stored.apiToken) {
    apiToken = String(stored.apiToken);
    return apiToken;
  }

  const response = await fetch(`${SERVER_BASE}/api/local-token`, {
    cache: 'no-store',
    headers: { Accept: 'application/json' }
  });
  if (!response.ok) throw new Error(`Token HTTP ${response.status}`);
  const data = await response.json();
  if (!data?.ok || !data?.token) throw new Error('Локальный токен недоступен');
  apiToken = String(data.token);
  await chrome.storage.local.set({ apiToken });
  return apiToken;
}

async function refreshSettings() {
  try {
    const response = await fetch(`${SERVER_BASE}/api/settings?t=${Date.now()}`, { cache: 'no-store' });
    if (!response.ok) return;
    const data = await response.json();
    if (data?.settings) {
      settings = { ...settings, ...data.settings };
    }
  } catch {
    // сервер может быть выключен
  }
}

async function postSourcesSnapshot() {
  try {
    const token = await ensureApiToken();
    const sources = [...tabStates.values()].map((state) => ({
      tabId: state.tabId,
      provider: state.provider,
      providerLabel: state.providerLabel,
      title: state.title,
      artist: state.artist,
      isPlaying: state.isPlaying,
      hasTrack: state.hasTrack,
      receivedAt: state.receivedAt
    }));
    await fetch(`${SERVER_BASE}/api/sources`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-TrackPulse-Token': token
      },
      body: JSON.stringify({ sources }),
      cache: 'no-store'
    });
  } catch {
    // ignore
  }
}

async function postSelectedState(force = false) {
  const state = chooseState();
  const fingerprint = JSON.stringify({
    tabId: state.tabId,
    provider: state.provider,
    title: state.title,
    artist: state.artist,
    album: state.album,
    artwork: state.artwork,
    duration: Math.round(state.duration * 4) / 4,
    position: Math.floor(state.position),
    positionSource: state.positionSource,
    level: Math.round((state.level || 0) * 40) / 40,
    isPlaying: state.isPlaying,
    hasTrack: state.hasTrack,
    revision: state.revision
  });

  if (!force && fingerprint === lastPostedFingerprint && Date.now() - lastPostAt < 70) return;

  // При кратком «пустом» состоянии не сбрасываем оверлей сразу — ждём hold.
  if (!state.hasTrack && lastPostedFingerprint && lastNonEmptyState) {
    if (holdEmptyTimer) return;
    holdEmptyTimer = setTimeout(() => {
      holdEmptyTimer = null;
      postSelectedState(true).catch(() => {});
    }, Number(settings.holdLastTrackMs) || 2800);
    return;
  }
  if (holdEmptyTimer) {
    clearTimeout(holdEmptyTimer);
    holdEmptyTimer = null;
  }

  try {
    const token = await ensureApiToken();
    const response = await fetch(`${SERVER_BASE}/api/track`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-TrackPulse-Token': token
      },
      body: JSON.stringify(state),
      cache: 'no-store'
    });
    if (response.status === 401) {
      apiToken = '';
      await chrome.storage.local.remove('apiToken');
      throw new Error('Неверный локальный токен — переподключите сервер');
    }
    if (!response.ok) throw new Error(`HTTP ${response.status}`);

    lastPostedFingerprint = fingerprint;
    lastPostAt = Date.now();
    await chrome.storage.local.set({
      serverConnected: true,
      lastError: '',
      lastState: state,
      statusUpdatedAt: Date.now()
    });
    postSourcesSnapshot().catch(() => {});
  } catch (error) {
    await chrome.storage.local.set({
      serverConnected: false,
      lastError: String(error?.message || error),
      lastState: state,
      statusUpdatedAt: Date.now()
    });
  }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === 'TRACKPULSE_STATE' && sender.tab?.id !== undefined) {
    const next = normalizeState(message.state || {}, sender.tab.id);
    tabStates.set(sender.tab.id, next);
    if (next.isPlaying && ALLOWED_PROVIDERS.has(next.provider)) {
      stickyProvider = next.provider;
    }
    postSelectedState().catch(() => {});
    sendResponse({ ok: true });
    return false;
  }

  if (message?.type === 'CHECK_SERVER') {
    (async () => {
      try {
        await ensureApiToken();
        await refreshSettings();
        const response = await fetch(`${SERVER_BASE}/health`, { cache: 'no-store' });
        const data = response.ok ? await response.json() : null;
        sendResponse({ ok: Boolean(data?.ok), data });
      } catch (error) {
        sendResponse({ ok: false, error: String(error?.message || error) });
      }
    })();
    return true;
  }

  if (message?.type === 'OPEN_OVERLAY') {
    chrome.tabs.create({ url: `${SERVER_BASE}/` });
    sendResponse({ ok: true });
    return false;
  }

  if (message?.type === 'OPEN_STATS') {
    chrome.tabs.create({ url: `${SERVER_BASE}/stats.html` });
    sendResponse({ ok: true });
    return false;
  }

  if (message?.type === 'OPEN_PRIVACY') {
    chrome.tabs.create({ url: chrome.runtime.getURL('privacy.html') });
    sendResponse({ ok: true });
    return false;
  }

  return false;
});

chrome.tabs.onRemoved.addListener((tabId) => {
  if (tabStates.delete(tabId)) postSelectedState(true).catch(() => {});
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.set({
    serverConnected: false,
    lastError: 'Локальный сервер ещё не проверен.',
    statusUpdatedAt: Date.now()
  });
});

refreshSettings().catch(() => {});
setInterval(() => refreshSettings().catch(() => {}), 10000);
setInterval(() => postSourcesSnapshot().catch(() => {}), 4000);
