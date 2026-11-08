'use strict';

const ADMIN_STORAGE_KEY = 'trackpulseAdminToken';

const elements = {
  sessionStatus: document.querySelector('#sessionStatus'),
  sessionToggle: document.querySelector('#sessionToggle'),
  modeSelect: document.querySelector('#modeSelect'),
  sessionSelect: document.querySelector('#sessionSelect'),
  sessionSelectWrap: document.querySelector('#sessionSelectWrap'),
  refreshButton: document.querySelector('#refreshButton'),
  exportButton: document.querySelector('#exportButton'),
  clearButton: document.querySelector('#clearButton'),
  exportFrom: document.querySelector('#exportFrom'),
  exportTo: document.querySelector('#exportTo'),
  trackCount: document.querySelector('#trackCount'),
  uniqueCount: document.querySelector('#uniqueCount'),
  averageDuration: document.querySelector('#averageDuration'),
  totalDuration: document.querySelector('#totalDuration'),
  shortestDuration: document.querySelector('#shortestDuration'),
  shortestTrack: document.querySelector('#shortestTrack'),
  longestDuration: document.querySelector('#longestDuration'),
  longestTrack: document.querySelector('#longestTrack'),
  mostFrequentTrack: document.querySelector('#mostFrequentTrack'),
  mostFrequentCount: document.querySelector('#mostFrequentCount'),
  topTracksChart: document.querySelector('#topTracksChart'),
  topArtistsChart: document.querySelector('#topArtistsChart'),
  historyBody: document.querySelector('#historyBody'),
  historyTitle: document.querySelector('#historyTitle'),
  sessionRange: document.querySelector('#sessionRange'),
  lockButton: document.querySelector('#lockButton'),
  openAdminButton: document.querySelector('#openAdminButton'),
  lockModal: document.querySelector('#lockModal'),
  lockPassword: document.querySelector('#lockPassword'),
  lockAccept: document.querySelector('#lockAccept'),
  lockCancel: document.querySelector('#lockCancel'),
  toast: document.querySelector('#toast')
};

let historyData = { activeSession: null, sessions: [], daemonMode: false };
let journalData = { tracks: [] };
let selectedSessionId = 'active';
let mode = 'journal';
let loading = false;
let toastTimer = null;
let renderedFingerprint = '';
let apiToken = '';
let daemonMode = false;

function showToast(message) {
  elements.toast.textContent = message;
  elements.toast.hidden = false;
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { elements.toast.hidden = true; }, 2600);
}

function formatDuration(seconds) {
  const value = Math.max(0, Number(seconds) || 0);
  const hours = Math.floor(value / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  const rest = Math.floor(value % 60);
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, '0')}:${String(rest).padStart(2, '0')}`
    : `${minutes}:${String(rest).padStart(2, '0')}`;
}

function formatClock(timestamp) {
  if (!Number(timestamp)) return '—';
  return new Date(Number(timestamp)).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
}

function formatDateTime(timestamp) {
  if (!Number(timestamp)) return '—';
  return new Date(Number(timestamp)).toLocaleString('ru-RU', {
    day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit'
  });
}

function trackName(track) {
  return `${track.artist || 'Неизвестный исполнитель'} — ${track.title || 'Без названия'}`;
}

function providerText(track) {
  if (track.providerLabel) return track.providerLabel;
  if (track.provider === 'vk') return 'VK';
  if (track.provider === 'yandex') return 'Яндекс Музыка';
  return '—';
}

function getSessions() {
  const result = [];
  if (historyData.activeSession) result.push({ ...historyData.activeSession, isActive: true });
  for (const session of [...(historyData.sessions || [])].reverse()) result.push({ ...session, isActive: false });
  return result;
}

function getSelectedSession() {
  const sessions = getSessions();
  if (selectedSessionId === 'active') return sessions.find((session) => session.isActive) || sessions[0] || null;
  return sessions.find((session) => session.id === selectedSessionId) || sessions[0] || null;
}

function getActiveTracks() {
  if (mode === 'journal') return [...(journalData.tracks || [])].reverse();
  return getSelectedSession()?.tracks || [];
}

function calculateStats(tracks) {
  const validDurations = tracks.filter((track) => Number(track.duration) > 0);
  const total = validDurations.reduce((sum, track) => sum + Number(track.duration), 0);
  const shortest = validDurations.reduce((best, track) => !best || track.duration < best.duration ? track : best, null);
  const longest = validDurations.reduce((best, track) => !best || track.duration > best.duration ? track : best, null);

  const songCounts = new Map();
  const artistCounts = new Map();
  for (const track of tracks) {
    const key = `${track.provider || ''}\u0000${track.artist || ''}\u0000${track.title || ''}`;
    const current = songCounts.get(key) || { track, count: 0 };
    current.count += 1;
    songCounts.set(key, current);
    const artist = track.artist || 'Неизвестный исполнитель';
    artistCounts.set(artist, (artistCounts.get(artist) || 0) + 1);
  }

  const topTracks = [...songCounts.values()].sort((a, b) => b.count - a.count || trackName(a.track).localeCompare(trackName(b.track), 'ru'));
  const topArtists = [...artistCounts.entries()].map(([name, count]) => ({ name, count })).sort((a, b) => b.count - a.count || a.name.localeCompare(b.name, 'ru'));

  return {
    count: tracks.length,
    unique: songCounts.size,
    total,
    average: validDurations.length ? total / validDurations.length : 0,
    shortest,
    longest,
    mostFrequent: topTracks[0] || null,
    topTracks,
    topArtists
  };
}

function renderBarChart(container, items, type) {
  container.innerHTML = '';
  if (!items.length) {
    container.className = 'bar-chart empty';
    container.textContent = 'Пока недостаточно данных';
    return;
  }

  container.className = 'bar-chart';
  const maximum = Math.max(...items.map((item) => item.count), 1);
  for (const item of items.slice(0, 7)) {
    const row = document.createElement('div');
    row.className = 'bar-row';
    const label = document.createElement('div');
    label.className = 'bar-label';
    const strong = document.createElement('strong');
    const small = document.createElement('span');
    if (type === 'track') {
      strong.textContent = item.track.title || 'Без названия';
      small.textContent = `${item.track.artist || 'Неизвестный исполнитель'} · ${providerText(item.track)}`;
    } else {
      strong.textContent = item.name;
      small.textContent = item.count === 1 ? '1 песня' : `${item.count} песен`;
    }
    label.append(strong, small);
    const bar = document.createElement('div');
    bar.className = 'bar-track';
    const fill = document.createElement('div');
    fill.className = 'bar-fill';
    fill.style.width = `${Math.max(3, (item.count / maximum) * 100)}%`;
    bar.append(fill);
    const value = document.createElement('div');
    value.className = 'bar-value';
    value.textContent = `×${item.count}`;
    row.append(label, bar, value);
    container.append(row);
  }
}

function renderSessionSelect() {
  const sessions = getSessions();
  const previous = selectedSessionId;
  elements.sessionSelect.innerHTML = '';

  if (!sessions.length) {
    elements.sessionSelect.add(new Option('Нет сохранённых эфиров', 'none'));
    elements.sessionSelect.disabled = true;
    selectedSessionId = 'none';
    return;
  }

  elements.sessionSelect.disabled = false;
  for (const session of sessions) {
    const value = session.isActive ? 'active' : session.id;
    const label = session.isActive
      ? `● Текущий эфир — ${formatDateTime(session.startedAt)}`
      : `${session.name || 'Эфир'} — ${formatDateTime(session.startedAt)}`;
    elements.sessionSelect.add(new Option(label, value));
  }

  const values = [...elements.sessionSelect.options].map((option) => option.value);
  selectedSessionId = values.includes(previous) ? previous : elements.sessionSelect.options[0].value;
  elements.sessionSelect.value = selectedSessionId;
}

function syncAdminButton() {
  const unlocked = Boolean(sessionStorage.getItem(ADMIN_STORAGE_KEY));
  elements.openAdminButton.hidden = !unlocked;
  elements.lockButton.classList.toggle('unlocked', unlocked);
}

function render() {
  const active = Boolean(historyData.activeSession) || daemonMode;
  if (daemonMode) {
    elements.sessionStatus.textContent = 'Эфир запущен';
    elements.sessionStatus.classList.add('active');
    elements.sessionToggle.hidden = true;
  } else {
    elements.sessionStatus.textContent = active ? 'Эфир записывается' : 'Эфир не запущен';
    elements.sessionStatus.classList.toggle('active', active);
    elements.sessionToggle.hidden = false;
    elements.sessionToggle.textContent = historyData.activeSession ? 'Завершить эфир' : 'Начать новый эфир';
  }

  elements.sessionSelectWrap.hidden = mode !== 'stream';
  elements.historyTitle.textContent = mode === 'journal' ? 'Постоянный журнал прослушивания' : 'Что играло во время эфира';
  syncAdminButton();
  renderSessionSelect();

  const session = getSelectedSession();
  const tracks = getActiveTracks();
  const stats = calculateStats(tracks);

  elements.trackCount.textContent = String(stats.count);
  elements.uniqueCount.textContent = `${stats.unique} уникальных`;
  elements.averageDuration.textContent = stats.average ? formatDuration(stats.average) : '—';
  elements.totalDuration.textContent = `Всего ${formatDuration(stats.total)}`;
  elements.shortestDuration.textContent = stats.shortest ? formatDuration(stats.shortest.duration) : '—';
  elements.shortestTrack.textContent = stats.shortest ? trackName(stats.shortest) : 'Нет данных';
  elements.longestDuration.textContent = stats.longest ? formatDuration(stats.longest.duration) : '—';
  elements.longestTrack.textContent = stats.longest ? trackName(stats.longest) : 'Нет данных';
  elements.mostFrequentTrack.textContent = stats.mostFrequent ? trackName(stats.mostFrequent.track) : '—';
  elements.mostFrequentCount.textContent = stats.mostFrequent
    ? `${stats.mostFrequent.count} ${stats.mostFrequent.count === 1 ? 'раз' : 'раза'}`
    : 'Нет повторов';

  renderBarChart(elements.topTracksChart, stats.topTracks, 'track');
  renderBarChart(elements.topArtistsChart, stats.topArtists, 'artist');

  if (mode === 'journal') {
    elements.sessionRange.textContent = tracks.length
      ? `${formatDateTime(tracks[tracks.length - 1]?.startedAt)} — ${formatDateTime(tracks[0]?.startedAt)}`
      : '';
  } else {
    elements.sessionRange.textContent = session
      ? `${formatDateTime(session.startedAt)} — ${session.isActive || daemonMode ? 'сейчас' : formatDateTime(session.endedAt)}`
      : '';
  }

  elements.historyBody.innerHTML = '';
  if (!tracks.length) {
    const row = document.createElement('tr');
    row.innerHTML = '<td colspan="6" class="empty-row">Пока нет записанных треков</td>';
    elements.historyBody.append(row);
    return;
  }

  tracks.forEach((track, index) => {
    const row = document.createElement('tr');
    const values = [
      index + 1,
      formatClock(track.startedAt),
      providerText(track),
      track.artist || 'Неизвестный исполнитель',
      track.title || 'Без названия',
      Number(track.duration) > 0 ? formatDuration(track.duration) : '—'
    ];
    for (const value of values) {
      const cell = document.createElement('td');
      cell.textContent = String(value);
      row.append(cell);
    }
    elements.historyBody.append(row);
  });
}

async function ensureToken() {
  if (apiToken) return apiToken;
  const response = await fetch(`/api/local-token?t=${Date.now()}`, { cache: 'no-store' });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || !data.token) throw new Error(data.error || 'Не удалось получить локальный токен');
  apiToken = String(data.token);
  return apiToken;
}

async function requestJson(url, options = {}) {
  const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) };
  if (options.method && options.method !== 'GET') {
    headers['X-TrackPulse-Token'] = await ensureToken();
  }
  const response = await fetch(url, { cache: 'no-store', ...options, headers });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data.ok === false) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

async function loadAll(silent = false, force = false) {
  if (loading) return;
  loading = true;
  try {
    const [nextHistory, nextJournal] = await Promise.all([
      requestJson(`/api/history?t=${Date.now()}`),
      requestJson(`/api/journal?t=${Date.now()}`)
    ]);
    daemonMode = Boolean(nextHistory.daemonMode);
    const fingerprint = JSON.stringify({
      mode,
      selectedSessionId,
      daemonMode,
      activeSession: nextHistory.activeSession || null,
      sessions: nextHistory.sessions || [],
      journal: nextJournal.tracks || []
    });
    historyData = nextHistory;
    journalData = nextJournal;
    if (force || fingerprint !== renderedFingerprint) {
      renderedFingerprint = fingerprint;
      render();
    }
  } catch (error) {
    if (!silent) showToast(`Ошибка: ${error.message}`);
  } finally {
    loading = false;
  }
}

function parseLocalInput(value) {
  if (!value) return null;
  const ms = new Date(value).getTime();
  return Number.isFinite(ms) ? ms : null;
}

function exportCsv() {
  const fromMs = parseLocalInput(elements.exportFrom.value);
  const toMs = parseLocalInput(elements.exportTo.value);
  let tracks = getActiveTracks();

  if (fromMs !== null || toMs !== null) {
    tracks = tracks.filter((track) => {
      const started = Number(track.startedAt) || 0;
      if (fromMs !== null && started < fromMs) return false;
      if (toMs !== null && started > toMs) return false;
      return true;
    });
  }

  if (!tracks.length) {
    showToast('В выбранном промежутке нет треков');
    return;
  }

  const lines = [['startedAt', 'provider', 'artist', 'title', 'album', 'duration']];
  for (const track of tracks) {
    lines.push([
      track.startedAt ? new Date(Number(track.startedAt)).toISOString() : '',
      providerText(track),
      track.artist || '',
      track.title || '',
      track.album || '',
      Number(track.duration) || 0
    ].map((value) => `"${String(value).replace(/"/g, '""')}"`));
  }

  const blob = new Blob([lines.map((line) => line.join(',')).join('\n')], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = mode === 'journal' ? 'trackpulse-journal-range.csv' : 'trackpulse-stream-range.csv';
  anchor.click();
  URL.revokeObjectURL(url);
  showToast(`CSV: ${tracks.length} трек(ов)`);
}

elements.sessionToggle.addEventListener('click', async () => {
  if (daemonMode) return;
  elements.sessionToggle.disabled = true;
  try {
    const url = historyData.activeSession ? '/api/session/stop' : '/api/session/start';
    await requestJson(url, { method: 'POST', body: '{}' });
    selectedSessionId = historyData.activeSession ? 'none' : 'active';
    mode = 'stream';
    elements.modeSelect.value = 'stream';
    await loadAll(false, true);
    showToast(historyData.activeSession ? 'Эфир начат' : 'Эфир завершён');
  } catch (error) {
    showToast(`Ошибка: ${error.message}`);
  } finally {
    elements.sessionToggle.disabled = false;
  }
});

elements.modeSelect.addEventListener('change', () => {
  mode = elements.modeSelect.value;
  render();
});

elements.sessionSelect.addEventListener('change', () => {
  selectedSessionId = elements.sessionSelect.value;
  render();
});

elements.refreshButton.addEventListener('click', () => loadAll(false, true));
elements.exportButton.addEventListener('click', () => exportCsv());

elements.clearButton.addEventListener('click', async () => {
  const confirmed = window.confirm(
    mode === 'journal'
      ? 'Очистить постоянный журнал прослушивания?'
      : 'Удалить всю историю эфиров?'
  );
  if (!confirmed) return;
  elements.clearButton.disabled = true;
  try {
    const url = mode === 'journal' ? '/api/journal/clear' : '/api/history/clear';
    await requestJson(url, { method: 'POST', body: '{}' });
    if (mode === 'stream') selectedSessionId = 'none';
    await loadAll(false, true);
    showToast('Очищено');
  } catch (error) {
    showToast(`Ошибка: ${error.message}`);
  } finally {
    elements.clearButton.disabled = false;
  }
});

elements.lockButton.addEventListener('click', () => {
  elements.lockModal.hidden = false;
  elements.lockPassword.value = '';
  elements.lockPassword.focus();
});

elements.lockCancel.addEventListener('click', () => {
  elements.lockModal.hidden = true;
});

elements.lockAccept.addEventListener('click', async () => {
  try {
    const data = await requestJson('/api/admin/login', {
      method: 'POST',
      body: JSON.stringify({ password: elements.lockPassword.value })
    });
    sessionStorage.setItem(ADMIN_STORAGE_KEY, data.adminToken);
    elements.lockModal.hidden = true;
    syncAdminButton();
    showToast('Админка разблокирована');
  } catch (error) {
    showToast(error.message);
  }
});

elements.lockPassword.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') elements.lockAccept.click();
});

elements.openAdminButton.addEventListener('click', () => {
  location.href = 'admin.html';
});

loadAll();
setInterval(() => loadAll(true), 2000);
syncAdminButton();
