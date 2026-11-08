(() => {
  'use strict';

  if (window.__TRACKPULSE_PAGE_READER__) return;
  window.__TRACKPULSE_PAGE_READER__ = true;

  const EVENT_NAME = 'trackpulse-now-playing';
  const HEARTBEAT_MS = 500;

  let lastSerialized = '';
  let lastMetadataKey = '';
  let revision = 0;
  let activeMediaElement = null;
  let interceptedPositionState = null;
  let interceptedPositionAt = 0;

  function finiteNumber(value, fallback = 0) {
    const number = Number(value);
    return Number.isFinite(number) && number >= 0 ? number : fallback;
  }

  function cleanText(value) {
    return typeof value === 'string' ? value.trim() : '';
  }

  function detectProvider() {
    const host = String(location.hostname || '').toLowerCase();
    if (host === 'music.yandex.ru' || host === 'music.yandex.com') return 'yandex';
    if (host === 'vk.com' || host === 'm.vk.com' || host === 'vk.ru' || host.endsWith('.vk.com') || host.endsWith('.vk.ru')) {
      return 'vk';
    }
    return 'unknown';
  }

  function rememberMediaElement(element) {
    if (!(element instanceof HTMLMediaElement)) return;
    activeMediaElement = element;
  }

  function patchMediaElements() {
    try {
      const originalPlay = HTMLMediaElement.prototype.play;
      if (!originalPlay.__trackpulseWrapped) {
        const wrappedPlay = function (...args) {
          rememberMediaElement(this);
          return originalPlay.apply(this, args);
        };
        Object.defineProperty(wrappedPlay, '__trackpulseWrapped', { value: true });
        HTMLMediaElement.prototype.play = wrappedPlay;
      }

      const originalLoad = HTMLMediaElement.prototype.load;
      if (!originalLoad.__trackpulseWrapped) {
        const wrappedLoad = function (...args) {
          rememberMediaElement(this);
          return originalLoad.apply(this, args);
        };
        Object.defineProperty(wrappedLoad, '__trackpulseWrapped', { value: true });
        HTMLMediaElement.prototype.load = wrappedLoad;
      }
    } catch {
      // Сайт может запретить переопределение прототипа.
    }
  }

  function patchMediaSessionPosition() {
    try {
      const mediaSession = navigator.mediaSession;
      if (!mediaSession || typeof mediaSession.setPositionState !== 'function') return;
      if (mediaSession.setPositionState.__trackpulseWrapped) return;

      const original = mediaSession.setPositionState;
      const wrapped = function (positionState) {
        if (positionState && typeof positionState === 'object') {
          const duration = finiteNumber(positionState.duration);
          const position = Math.min(finiteNumber(positionState.position), duration || Number.MAX_SAFE_INTEGER);
          const playbackRate = finiteNumber(positionState.playbackRate, 1) || 1;
          interceptedPositionState = { duration, position, playbackRate };
          interceptedPositionAt = performance.now();
        } else {
          interceptedPositionState = null;
          interceptedPositionAt = 0;
        }
        return arguments.length === 0
          ? original.call(mediaSession)
          : original.call(mediaSession, positionState);
      };
      Object.defineProperty(wrapped, '__trackpulseWrapped', { value: true });

      try {
        Object.defineProperty(mediaSession, 'setPositionState', {
          configurable: true,
          writable: true,
          value: wrapped
        });
      } catch {
        const prototype = Object.getPrototypeOf(mediaSession);
        Object.defineProperty(prototype, 'setPositionState', {
          configurable: true,
          writable: true,
          value: wrapped
        });
      }
    } catch {
      // На отдельных сборках свойство может быть недоступно для записи.
    }
  }

  function getBestMediaElement() {
    if (activeMediaElement) {
      const duration = finiteNumber(activeMediaElement.duration);
      const position = finiteNumber(activeMediaElement.currentTime);
      if (duration > 0 || position > 0 || !activeMediaElement.paused) return activeMediaElement;
    }

    const mediaElements = [...document.querySelectorAll('audio, video')];
    if (!mediaElements.length) return null;

    const playing = mediaElements.find((media) =>
      !media.paused && !media.ended && (finiteNumber(media.duration) > 0 || finiteNumber(media.currentTime) > 0)
    );
    if (playing) {
      rememberMediaElement(playing);
      return playing;
    }

    const best = mediaElements
      .filter((media) => finiteNumber(media.duration) > 0 || finiteNumber(media.currentTime) > 0)
      .sort((a, b) => finiteNumber(b.currentTime) - finiteNumber(a.currentTime))[0] || mediaElements[0];
    rememberMediaElement(best);
    return best;
  }

  function readTimelineFromDom() {
    const selectors = [
      '[role="slider"][aria-valuemax]',
      '[role="progressbar"][aria-valuemax]',
      'input[type="range"][max]'
    ];
    const candidates = [...document.querySelectorAll(selectors.join(','))];

    let best = null;
    for (const element of candidates) {
      const label = `${element.getAttribute('aria-label') || ''} ${element.getAttribute('title') || ''}`.toLowerCase();
      if (/громк|volume|звук/.test(label)) continue;

      const maximum = finiteNumber(element.getAttribute('aria-valuemax') ?? element.max);
      const current = finiteNumber(element.getAttribute('aria-valuenow') ?? element.value);
      if (maximum < 20 || maximum > 86400 || current > maximum + 1) continue;

      const score = (/врем|пози|трек|песн|seek|progress|time|аудио/.test(label) ? 10 : 0) + maximum / 10000;
      if (!best || score > best.score) best = { duration: maximum, position: current, score };
    }

    return best ? { duration: best.duration, position: best.position } : null;
  }

  function getPositionState(isPlaying) {
    const media = getBestMediaElement();
    const mediaDuration = finiteNumber(media?.duration);
    const mediaPosition = finiteNumber(media?.currentTime);

    if (media && (mediaDuration > 0 || mediaPosition > 0)) {
      return {
        duration: mediaDuration,
        position: Math.min(mediaPosition, mediaDuration || Number.MAX_SAFE_INTEGER),
        source: 'media-element'
      };
    }

    if (interceptedPositionState?.duration > 0) {
      let position = interceptedPositionState.position;
      if (isPlaying && interceptedPositionAt) {
        position += ((performance.now() - interceptedPositionAt) / 1000) * interceptedPositionState.playbackRate;
      }
      return {
        duration: interceptedPositionState.duration,
        position: Math.min(position, interceptedPositionState.duration),
        source: 'media-session-position'
      };
    }

    const domTimeline = readTimelineFromDom();
    if (domTimeline) return { ...domTimeline, source: 'dom-slider' };

    return { duration: 0, position: 0, source: 'unknown' };
  }

  function getArtwork(metadata) {
    const artwork = Array.isArray(metadata?.artwork) ? metadata.artwork : [];
    if (!artwork.length) return '';

    const sorted = [...artwork].sort((a, b) => {
      const parseWidth = (sizes) => {
        const match = String(sizes || '').match(/(\d+)x(\d+)/i);
        return match ? Number(match[1]) : 0;
      };
      return parseWidth(b.sizes) - parseWidth(a.sizes);
    });

    const source = cleanText(sorted[0]?.src);
    return /^https:\/\//i.test(source) ? source : '';
  }

  function fallbackFromDocumentTitle(provider) {
    let title = cleanText(document.title);
    if (provider === 'yandex') {
      title = title
        .replace(/\s*[—–|-]\s*Яндекс Музыка.*$/i, '')
        .replace(/\s*[—–|-]\s*Yandex Music.*$/i, '');
      if (!title || /^Яндекс Музыка$/i.test(title)) return { title: '', artist: '' };
    } else if (provider === 'vk') {
      title = title
        .replace(/\s*[—–|-]\s*VK.*$/i, '')
        .replace(/\s*[—–|-]\s*ВКонтакте.*$/i, '')
        .replace(/^Аудиозаписи\s*[—–|-]\s*/i, '');
      if (!title || /^(VK|ВКонтакте|Аудиозаписи)$/i.test(title)) return { title: '', artist: '' };
    }

    const parts = title.split(/\s+[—–]\s+/).map(cleanText).filter(Boolean);
    if (parts.length >= 2) {
      // Яндекс чаще: «Трек — Артист», ВК часто: «Артист — Трек» в title.
      if (provider === 'vk') return { artist: parts[0], title: parts.slice(1).join(' — ') };
      return { title: parts[0], artist: parts.slice(1).join(' — ') };
    }
    return { title, artist: '' };
  }

  function readVkDomFallback() {
    const titleNode = document.querySelector(
      '.audio_page_player_title .audio_page_player__title_song, .AudioPlayerBlock__title, [class*="AudioPlayer"] [class*="title"]'
    );
    const artistNode = document.querySelector(
      '.audio_page_player_title .audio_page_player__title_performer, .AudioPlayerBlock__artist, [class*="AudioPlayer"] [class*="artist"], [class*="AudioPlayer"] [class*="subtitle"]'
    );

    const title = cleanText(titleNode?.textContent);
    const artist = cleanText(artistNode?.textContent);
    if (!title && !artist) return null;
    return { title, artist };
  }

  function readState() {
    patchMediaSessionPosition();

    const provider = detectProvider();
    const mediaSession = 'mediaSession' in navigator ? navigator.mediaSession : null;
    const metadata = mediaSession?.metadata || null;
    const media = getBestMediaElement();
    const fallback = fallbackFromDocumentTitle(provider);
    const vkDom = provider === 'vk' ? readVkDomFallback() : null;

    const title = cleanText(metadata?.title) || cleanText(vkDom?.title) || fallback.title;
    const artist = cleanText(metadata?.artist) || cleanText(vkDom?.artist) || fallback.artist;
    const album = cleanText(metadata?.album);
    const sessionPlaybackState = cleanText(mediaSession?.playbackState);
    const isPlaying = media
      ? !media.paused && !media.ended
      : sessionPlaybackState === 'playing';

    const timeline = getPositionState(isPlaying);
    const metadataKey = [provider, title, artist, album, getArtwork(metadata)].join('\u0000');
    if (metadataKey !== lastMetadataKey) {
      revision += 1;
      lastMetadataKey = metadataKey;
    }

    return {
      provider,
      pageUrl: location.href,
      title,
      artist,
      album,
      artwork: getArtwork(metadata),
      duration: timeline.duration,
      position: timeline.position,
      positionSource: timeline.source,
      isPlaying,
      hasTrack: Boolean(title || artist),
      revision,
      capturedAt: Date.now()
    };
  }

  function publish(force = false) {
    try {
      const state = readState();
      const serialized = JSON.stringify(state);
      if (!force && serialized === lastSerialized) return;
      lastSerialized = serialized;
      window.dispatchEvent(new CustomEvent(EVENT_NAME, { detail: state }));
    } catch (error) {
      window.dispatchEvent(new CustomEvent(EVENT_NAME, {
        detail: {
          provider: detectProvider(),
          hasTrack: false,
          isPlaying: false,
          title: '',
          artist: '',
          album: '',
          artwork: '',
          duration: 0,
          position: 0,
          positionSource: 'error',
          revision,
          capturedAt: Date.now(),
          readerError: String(error?.message || error)
        }
      }));
    }
  }

  patchMediaElements();
  patchMediaSessionPosition();

  const observer = new MutationObserver(() => publish());
  const startObserver = () => {
    if (document.documentElement) {
      observer.observe(document.documentElement, {
        subtree: true,
        childList: true,
        attributes: true,
        attributeFilter: ['src', 'title', 'aria-label', 'aria-valuenow', 'aria-valuemax']
      });
    } else {
      requestAnimationFrame(startObserver);
    }
  };

  for (const eventName of ['play', 'playing', 'pause', 'durationchange', 'timeupdate', 'loadedmetadata', 'ended', 'emptied']) {
    document.addEventListener(eventName, (event) => {
      if (event.target instanceof HTMLMediaElement) {
        rememberMediaElement(event.target);
      }
      publish(true);
    }, true);
  }

  startObserver();
  publish(true);
  setInterval(() => publish(true), HEARTBEAT_MS);
})();
