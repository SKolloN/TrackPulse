'use strict';

const address = 'http://127.0.0.1:18181/';
const GITHUB_RELEASES = 'https://github.com/SKolloN/TrackPulse/releases';
const GITHUB_API_LATEST = 'https://api.github.com/repos/SKolloN/TrackPulse/releases/latest';

const statusDot = document.querySelector('#statusDot');
const statusText = document.querySelector('#statusText');
const track = document.querySelector('#track');
const errorBox = document.querySelector('#error');
const sourceBadge = document.querySelector('#sourceBadge');
const updateBanner = document.querySelector('#updateBanner');
const versionLabel = document.querySelector('#versionLabel');

function setStatus(ok, message) {
  statusDot.className = `status-dot ${ok ? 'ok' : 'bad'}`;
  statusText.textContent = message;
}

function renderSource(state) {
  if (!state?.hasTrack || !state.provider) {
    sourceBadge.hidden = true;
    sourceBadge.textContent = '';
    sourceBadge.className = 'source-badge';
    return;
  }

  sourceBadge.hidden = false;
  sourceBadge.className = `source-badge ${state.provider}`;
  sourceBadge.textContent = state.provider === 'vk'
    ? 'Источник: VK'
    : state.provider === 'yandex'
      ? 'Источник: Яндекс Музыка'
      : `Источник: ${state.providerLabel || state.provider}`;
}

function parseVersion(tag) {
  return String(tag || '').replace(/^v/i, '').trim();
}

function compareVersions(a, b) {
  const pa = parseVersion(a).split('.').map((x) => Number(x) || 0);
  const pb = parseVersion(b).split('.').map((x) => Number(x) || 0);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i += 1) {
    const da = pa[i] || 0;
    const db = pb[i] || 0;
    if (da > db) return 1;
    if (da < db) return -1;
  }
  return 0;
}

async function checkForUpdates(manual = false) {
  const localVersion = chrome.runtime.getManifest().version;
  versionLabel.textContent = `v${localVersion}`;
  try {
    const response = await fetch(GITHUB_API_LATEST, {
      cache: 'no-store',
      headers: { Accept: 'application/vnd.github+json' }
    });
    if (!response.ok) throw new Error(`GitHub HTTP ${response.status}`);
    const data = await response.json();
    const remote = parseVersion(data.tag_name || data.name || '');
    if (!remote) throw new Error('Не удалось прочитать версию релиза');

    if (compareVersions(remote, localVersion) > 0) {
      updateBanner.hidden = false;
      updateBanner.textContent = `Доступна ${remote}. Запустите UPDATE.bat в папке расширения, затем Reload в edge://extensions.`;
      if (manual) {
        const open = window.confirm(`Найдена версия ${remote}. Открыть страницу релизов?`);
        if (open) chrome.tabs.create({ url: GITHUB_RELEASES });
      }
    } else {
      updateBanner.hidden = true;
      if (manual) window.alert(`У вас актуальная версия ${localVersion}.`);
    }
  } catch (error) {
    if (manual) window.alert(`Проверка обновлений не удалась: ${error.message}`);
  }
}

async function refresh() {
  const stored = await chrome.storage.local.get(['lastState', 'lastError']);
  const serverResponse = await chrome.runtime.sendMessage({ type: 'CHECK_SERVER' });

  setStatus(serverResponse?.ok, serverResponse?.ok ? 'Локальный сервер подключён' : 'Сервер не запущен');

  const state = stored.lastState;
  renderSource(state);
  track.textContent = state?.hasTrack
    ? `${state.artist || 'Неизвестный исполнитель'} — ${state.title || 'Без названия'}${state.isPlaying ? '' : ' · пауза'}`
    : 'Откройте Яндекс Музыку или VK и включите трек.';

  const error = serverResponse?.ok ? '' : (stored.lastError || serverResponse?.error || 'Запустите INSTALL.bat или start-daemon.bat');
  errorBox.hidden = !error;
  errorBox.textContent = error;
}

document.querySelector('#openOverlay').addEventListener('click', () => {
  chrome.runtime.sendMessage({ type: 'OPEN_OVERLAY' });
});

document.querySelector('#openStats').addEventListener('click', () => {
  chrome.runtime.sendMessage({ type: 'OPEN_STATS' });
});

document.querySelector('#openPrivacy').addEventListener('click', () => {
  chrome.runtime.sendMessage({ type: 'OPEN_PRIVACY' });
});

document.querySelector('#openGithub').addEventListener('click', () => {
  chrome.tabs.create({ url: GITHUB_RELEASES });
});

document.querySelector('#checkUpdate').addEventListener('click', () => {
  checkForUpdates(true).catch(() => {});
});

document.querySelector('#copyAddress').addEventListener('click', async (event) => {
  await navigator.clipboard.writeText(address);
  const button = event.currentTarget;
  const oldText = button.textContent;
  button.textContent = 'Адрес скопирован';
  setTimeout(() => { button.textContent = oldText; }, 1200);
});

versionLabel.textContent = `v${chrome.runtime.getManifest().version}`;
refresh().catch((error) => {
  setStatus(false, 'Ошибка расширения');
  errorBox.hidden = false;
  errorBox.textContent = String(error?.message || error);
});
checkForUpdates(false).catch(() => {});
setInterval(() => refresh().catch(() => {}), 1000);
