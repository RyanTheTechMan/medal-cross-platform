/* Injected into the imported renderer. This owns only short-lived source
 * audition nodes; encoded recording packets never cross the renderer IPC. */
(function installNativeAudioPreviewController() {
  if (window.NativeMedalAudioPreviewController) return;
  const state = {
    generation: 0,
    uuid: null,
    path: null,
    video: null,
    baselineMuted: false,
    context: null,
    buses: new Map(),
    listeners: [],
    preparing: false,
  };
  const emitError = error => {
    window.dispatchEvent(new CustomEvent('native-audio-preview-error', {
      detail: { message: String(error?.message || error || 'Audio preview unavailable') }
    }));
  };
  const pauseBuses = () => {
    for (const bus of state.buses.values()) {
      try { bus.audio.pause(); } catch {}
    }
  };
  const detach = () => {
    state.generation += 1;
    pauseBuses();
    for (const remove of state.listeners.splice(0)) {
      try { remove(); } catch {}
    }
    for (const bus of state.buses.values()) {
      try { bus.source.disconnect(); bus.gain.disconnect(); } catch {}
      try { bus.audio.removeAttribute('src'); bus.audio.load(); } catch {}
    }
    state.buses.clear();
    if (state.context) {
      try { state.context.close(); } catch {}
    }
    state.context = null;
    if (state.video && state.baselineMuted === false) state.video.muted = false;
    state.video = null;
    state.uuid = null;
    state.path = null;
    state.preparing = false;
  };
  const seekBus = bus => {
    if (!state.video || !Number.isFinite(state.video.currentTime)) return;
    try {
      if (Math.abs((bus.audio.currentTime || 0) - state.video.currentTime) > 0.08) {
        bus.audio.currentTime = Math.max(0, state.video.currentTime);
      }
    } catch {}
  };
  const sync = async () => {
    if (!state.video || state.preparing) return;
    const playing = !state.video.paused && !state.video.ended;
    if (playing) {
      try { await state.context?.resume(); } catch {}
    }
    for (const bus of state.buses.values()) {
      seekBus(bus);
      bus.audio.playbackRate = state.video.playbackRate || 1;
      if (playing) bus.audio.play().catch(emitError);
      else bus.audio.pause();
    }
  };
  const attach = async ({ uuid, path, video, streams }) => {
    if (!uuid || !path || !video) return;
    detach();
    const generation = state.generation;
    state.uuid = String(uuid);
    state.path = String(path);
    state.video = video;
    state.baselineMuted = video.muted;
    const sources = (Array.isArray(streams) ? streams : []).filter(stream =>
      stream && stream.index !== undefined && stream.logicalId !== 'all-audio' &&
      stream.title !== 'All Audio' && stream.isIncludeInMix !== false);
    if (!sources.length) return;
    state.preparing = true;
    video.muted = true;
    state.context = new AudioContext();
    try {
      for (const stream of sources) {
        if (generation !== state.generation) return;
        const prepared = await window.MedalIPC?.nativeAudioPreview?.prepare({
          uuid: state.uuid, path: state.path, index: Number(stream.index), generation
        });
        if (generation !== state.generation || !prepared?.url) return;
        const audio = new Audio();
        audio.preload = 'auto';
        audio.crossOrigin = 'anonymous';
        audio.src = prepared.url;
        const source = state.context.createMediaElementSource(audio);
        const gain = state.context.createGain();
        gain.gain.value = stream.isMuted ? 0 : 1;
        source.connect(gain).connect(state.context.destination);
        state.buses.set(Number(stream.index), { audio, source, gain });
      }
      const onPlay = () => { sync().catch(emitError); };
      const onPause = () => pauseBuses();
      const onSeek = () => { for (const bus of state.buses.values()) seekBus(bus); };
      const onRate = () => { sync().catch(emitError); };
      const onEnd = () => pauseBuses();
      for (const [name, listener] of [['play', onPlay], ['pause', onPause], ['seeking', onSeek],
        ['seeked', onSeek], ['ratechange', onRate], ['ended', onEnd]]) {
        video.addEventListener(name, listener);
        state.listeners.push(() => video.removeEventListener(name, listener));
      }
      state.preparing = false;
      await sync();
    } catch (error) {
      emitError(error);
      detach();
    }
  };
  const toggle = (index, muted) => {
    const bus = state.buses.get(Number(index));
    if (!bus || !state.context) return;
    try {
      bus.gain.gain.setTargetAtTime(muted ? 0 : 1, state.context.currentTime, 0.01);
    } catch (error) { emitError(error); }
  };
  const reset = () => {
    for (const bus of state.buses.values()) {
      try { bus.gain.gain.setTargetAtTime(0, state.context?.currentTime || 0, 0.01); } catch {}
    }
    detach();
  };
  window.NativeMedalAudioPreviewController = Object.freeze({ attach, detach, reset, toggle });
})();
