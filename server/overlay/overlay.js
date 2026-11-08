'use strict';

const config = Object.assign({
  pollIntervalMs: 100,
  visibleDurationMs: 7000,
  longTrackThresholdSeconds: 230,
  endTriggerSeconds: 15,
  hideWhenEmpty: true,
  hideWhenPaused: false,
  emptyHideDelayMs: 500,
  scrollSpeedPxPerSecond: 42,
  marqueePauseSeconds: 1.1,
  marqueeEndPauseSeconds: 1.0,
  unknownArtistText: 'TrackPulse',
  showSourceLabel: true
}, window.OVERLAY_CONFIG || {});

function applyThemePayload(theme) {
  if (!theme || typeof theme !== 'object') return;
  const vars = theme.cssVars || {};
  const root = document.documentElement;
  for (const [key, value] of Object.entries(vars)) {
    if (value === undefined || value === null || value === '') continue;
    root.style.setProperty(`--${key}`, String(value));
  }
  if (theme.config && typeof theme.config === 'object') {
    Object.assign(config, theme.config);
  }
}

async function loadTheme() {
  try {
    const response = await fetch(`/api/theme?t=${Date.now()}`, { cache: 'no-store' });
    if (!response.ok) return;
    const data = await response.json();
    applyThemePayload(data.theme);
  } catch {
    // fallback to defaults in CSS/config.js
  }
}

loadTheme();
setInterval(() => loadTheme().catch(() => {}), 5000);

const elements = {
  widget: document.querySelector('#widget'),
  title: document.querySelector('#title'),
  artist: document.querySelector('#artist'),
  titleMarquee: document.querySelector('#titleMarquee'),
  artistMarquee: document.querySelector('#artistMarquee'),
  currentTime: document.querySelector('#currentTime'),
  duration: document.querySelector('#duration'),
  progressBar: document.querySelector('#progressBar'),
  statusLabel: document.querySelector('#statusLabel'),
  sourceLabel: document.querySelector('#sourceLabel')
};

let state = null;
let trackKey = '';
let lastReceivedAtClient = 0;
let hideTimer = null;
let polling = false;
let cueSet = new Set();
let switchingTimer = null;
let currentCue = '';

function formatTime(seconds, unknown = '0:00') {
  const value = Number(seconds);
  if (!Number.isFinite(value) || value < 0) return unknown;
  const minutes = Math.floor(value / 60);
  const rest = Math.floor(value % 60);
  return `${minutes}:${String(rest).padStart(2, '0')}`;
}

function calculateTrackKey(nextState) {
  return [nextState.title, nextState.artist, nextState.album].join('\u0000');
}

function resetMarquee(container, track) {
  container.classList.remove('is-overflowing');
  track.style.removeProperty('--marquee-distance');
  track.style.removeProperty('--marquee-duration');
  track.style.removeProperty('--marquee-delay');
  void track.offsetWidth;

  const available = container.clientWidth;
  const content = track.scrollWidth;
  const overflow = Math.max(0, content - available);
  if (overflow < 2) return 0;

  const travelSeconds = overflow / Math.max(10, config.scrollSpeedPxPerSecond);
  const animationSeconds = Math.max(
    5.4,
    travelSeconds + config.marqueePauseSeconds + config.marqueeEndPauseSeconds
  );

  track.style.setProperty('--marquee-distance', `${-overflow}px`);
  track.style.setProperty('--marquee-duration', `${animationSeconds.toFixed(2)}s`);
  track.style.setProperty('--marquee-delay', `${config.marqueePauseSeconds}s`);
  container.classList.add('is-overflowing');

  return (config.marqueePauseSeconds + animationSeconds + 0.2) * 1000;
}

function updateMarquees() {
  const titleMs = resetMarquee(elements.titleMarquee, elements.title);
  const artistMs = resetMarquee(elements.artistMarquee, elements.artist);
  return Math.max(titleMs, artistMs);
}

function clearHideTimer() {
  if (hideTimer) clearTimeout(hideTimer);
  hideTimer = null;
}

function showWidget() {
  clearHideTimer();
  elements.widget.classList.remove('is-hidden');
}

function hideWidget(delayed = false) {
  clearHideTimer();
  const hide = () => elements.widget.classList.add('is-hidden');
  if (delayed) hideTimer = setTimeout(hide, config.emptyHideDelayMs);
  else hide();
}

function scheduleAutoHide(marqueeDurationMs = 0, minimumVisibleMs = 0) {
  clearHideTimer();
  const visibleFor = Math.max(
    Number(config.visibleDurationMs) || 0,
    Number(minimumVisibleMs) || 0,
    marqueeDurationMs + 500
  );
  hideTimer = setTimeout(() => hideWidget(false), visibleFor);
}

function updateText(nextState) {
  elements.title.textContent = nextState.title || 'Без названия';
  elements.artist.textContent = nextState.artist || config.unknownArtistText;
  elements.duration.textContent = Number(nextState.duration) > 0
    ? formatTime(nextState.duration)
    : '—:—';
  return updateMarquees();
}

function showCue(cue, { transition = false } = {}) {
  if (!state?.hasTrack || cueSet.has(cue)) return;
  cueSet.add(cue);
  currentCue = cue;

  const wasHidden = elements.widget.classList.contains('is-hidden');
  if (!transition || wasHidden) {
    if (switchingTimer) clearTimeout(switchingTimer);
    elements.widget.classList.remove('is-switching-out', 'is-switching-in');
    const marqueeMs = updateText(state);
    showWidget();
    const minimumVisibleMs = cue === 'end'
      ? (Number(config.endTriggerSeconds) || 15) * 1000 + 2500
      : 0;
    scheduleAutoHide(marqueeMs, minimumVisibleMs);
    return;
  }

  clearHideTimer();
  elements.widget.classList.remove('is-switching-in');
  elements.widget.classList.add('is-switching-out');

  switchingTimer = setTimeout(() => {
    elements.widget.classList.remove('is-switching-out');
    const marqueeMs = updateText(state);
    elements.widget.classList.add('is-switching-in');
    showWidget();
    const minimumVisibleMs = cue === 'end'
      ? (Number(config.endTriggerSeconds) || 15) * 1000 + 2500
      : 0;
    scheduleAutoHide(marqueeMs, minimumVisibleMs);

    switchingTimer = setTimeout(() => {
      elements.widget.classList.remove('is-switching-in');
    }, 460);
  }, 255);
}

function getEstimatedPosition() {
  if (!state?.hasTrack) return 0;
  let position = Number(state.position) || 0;
  const duration = Number(state.duration) || 0;

  if (state.isPlaying && lastReceivedAtClient) {
    position += (performance.now() - lastReceivedAtClient) / 1000;
  }
  return duration > 0 ? Math.min(position, duration) : Math.max(0, position);
}

function evaluateCues(position, duration) {
  if (!state?.hasTrack || duration <= 0) return;

  if (duration > Number(config.longTrackThresholdSeconds || 230)) {
    const middleAt = duration / 2;
    if (position >= middleAt) showCue('middle');
  }

  const endTrigger = Math.min(
    Math.max(8, Number(config.endTriggerSeconds) || 15),
    Math.max(8, duration * 0.22)
  );
  if (position >= Math.max(0, duration - endTrigger)) showCue('end');
}

function applyState(nextState) {
  const hasTrack = Boolean(nextState?.hasTrack && (nextState.title || nextState.artist));
  const shouldHideForState = !hasTrack || (config.hideWhenPaused && !nextState.isPlaying);

  if (shouldHideForState) {
    if (config.hideWhenEmpty) hideWidget(true);
    state = nextState;
    return;
  }

  const nextKey = calculateTrackKey(nextState);
  const changed = nextKey !== trackKey;
  const previousState = state;

  state = nextState;
  lastReceivedAtClient = performance.now();
  elements.widget.classList.toggle('is-paused', !nextState.isPlaying);
  elements.statusLabel.textContent = nextState.isPlaying ? 'СЕЙЧАС ИГРАЕТ' : 'НА ПАУЗЕ';

  if (elements.sourceLabel) {
    const label = nextState.providerLabel || (nextState.provider === 'vk' ? 'VK' : nextState.provider === 'yandex' ? 'Яндекс Музыка' : '');
    const show = Boolean(config.showSourceLabel && label);
    elements.sourceLabel.hidden = !show;
    elements.sourceLabel.textContent = label;
  }

  if (!changed) {
    elements.duration.textContent = Number(nextState.duration) > 0
      ? formatTime(nextState.duration)
      : '—:—';
    return;
  }

  const previousHadTrack = Boolean(previousState?.hasTrack && trackKey);
  trackKey = nextKey;
  cueSet = new Set();
  showCue('start', { transition: previousHadTrack });
}

async function poll() {
  if (polling) return;
  polling = true;
  try {
    const response = await fetch(`/api/state?t=${Date.now()}`, { cache: 'no-store' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    applyState(await response.json());
  } catch {
    if (config.hideWhenEmpty) hideWidget(true);
  } finally {
    polling = false;
  }
}

function animate() {
  if (state?.hasTrack) {
    const position = getEstimatedPosition();
    const duration = Number(state.duration) || 0;

    elements.currentTime.textContent = formatTime(position);
    elements.duration.textContent = duration > 0 ? formatTime(duration) : '—:—';
    elements.progressBar.style.width = duration > 0
      ? `${Math.max(0, Math.min(100, (position / duration) * 100))}%`
      : '0%';

    evaluateCues(position, duration);
  }

  requestAnimationFrame(animate);
}

window.addEventListener('resize', () => {
  if (!elements.widget.classList.contains('is-hidden')) {
    const marqueeMs = updateMarquees();
    const minimumVisibleMs = currentCue === 'end'
      ? (Number(config.endTriggerSeconds) || 15) * 1000 + 2500
      : 0;
    scheduleAutoHide(marqueeMs, minimumVisibleMs);
  }
});

setInterval(poll, Math.max(80, config.pollIntervalMs));
poll();
animate();
