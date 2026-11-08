window.OVERLAY_CONFIG = {
  pollIntervalMs: 100,

  // Карточка показывается в начале и конце каждой песни.
  // Для песен длиннее 3:50 добавляется показ в середине.
  visibleDurationMs: 7000,
  longTrackThresholdSeconds: 230,
  endTriggerSeconds: 15,

  hideWhenEmpty: true,
  hideWhenPaused: false,
  emptyHideDelayMs: 500,

  // Длинная строка автоматически продлевает время показа,
  // чтобы успеть пройти от начала до конца.
  scrollSpeedPxPerSecond: 42,
  marqueePauseSeconds: 1.1,
  marqueeEndPauseSeconds: 1.0,

  unknownArtistText: 'TrackPulse',
  showSourceLabel: true
};
