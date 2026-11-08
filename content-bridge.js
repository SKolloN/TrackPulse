(() => {
  'use strict';

  if (window.__TRACKPULSE_CONTENT_BRIDGE__) return;
  window.__TRACKPULSE_CONTENT_BRIDGE__ = true;

  const EVENT_NAME = 'trackpulse-now-playing';
  const ALLOWED_PROVIDERS = new Set(['yandex', 'vk']);

  function sanitize(detail) {
    if (!detail || !ALLOWED_PROVIDERS.has(detail.provider)) return null;

    const text = (value, max = 500) =>
      typeof value === 'string' ? value.trim().slice(0, max) : '';
    const number = (value) => {
      const result = Number(value);
      return Number.isFinite(result) && result >= 0 ? result : 0;
    };

    const artwork = text(detail.artwork, 3000);
    return {
      provider: detail.provider,
      // pageUrl не уходит дальше bridge — только для локальной отладки при необходимости.
      title: text(detail.title),
      artist: text(detail.artist),
      album: text(detail.album),
      artwork: /^https:\/\//i.test(artwork) ? artwork : '',
      duration: number(detail.duration),
      position: number(detail.position),
      positionSource: text(detail.positionSource, 100),
      level: Math.max(0, Math.min(1, number(detail.level))),
      levelSource: text(detail.levelSource, 40),
      isPlaying: Boolean(detail.isPlaying),
      hasTrack: Boolean(detail.hasTrack),
      revision: Math.max(0, Math.floor(number(detail.revision))),
      capturedAt: number(detail.capturedAt) || Date.now()
    };
  }

  window.addEventListener(EVENT_NAME, (event) => {
    const state = sanitize(event.detail);
    if (!state) return;

    chrome.runtime.sendMessage({ type: 'TRACKPULSE_STATE', state }).catch(() => {
      // Service worker может перезапуститься — следующий heartbeat повторит отправку.
    });
  });
})();
