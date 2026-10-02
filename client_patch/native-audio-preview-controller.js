/* Audition adapter for the imported Audio popovers, not a replacement player.
 * Only opaque finalized-file URLs cross IPC; capture stays entirely native. */
(function installNativeAudioPreviewController() {
  if (window.NativeMedalAudioPreviewController) return;
  let context, active, restore, generation = 0;
  const originals = new WeakMap();
  const audioContext = () => context ||= new AudioContext();
  const release = lease => lease && window.MedalIPC.nativeAudioPreview.release({ lease }).catch(() => {});
  const current = s => active === s && s.generation === generation;
  const status = (s, name, message = '') => {
    s.status = name;
    if (s.label) { s.label.textContent = message; s.label.hidden = !message; }
    window.dispatchEvent(new CustomEvent('native-audio-preview-state', { detail: { state: name, message } }));
  };
  const pause = s => { for (const b of s.buses.values()) b.audio.pause(); };
  const gain = (s, bus) => {
    const value = s.status === 'ready' && !s.seeking && !bus.waiting && !s.video.muted && !bus.muted ? s.video.volume : 0;
    const param = bus.gain.gain;
    param.cancelScheduledValues(context.currentTime);
    param.setTargetAtTime(value, context.currentTime, 0.004);
  };
  const gains = s => { for (const bus of s.buses.values()) gain(s, bus); };
  const fail = (s, error) => {
    if (!current(s)) return;
    status(s, 'error', `Audio preview unavailable: ${error?.message || error}`);
    pause(s); gains(s); s.video.pause();
    // Keep the original audio disconnected. Failing open would leak a muted master.
  };
  function baseline(video) {
    let node = originals.get(video);
    if (!node) {
      const source = audioContext().createMediaElementSource(video);
      const gate = context.createGain();
      source.connect(gate).connect(context.destination);
      originals.set(video, node = { source, gate });
    }
    node.gate.gain.value = 0;
    return node;
  }
  function dispose(s, restore = true) {
    if (!s) return;
    ++generation; active = null;
    pause(s); clearInterval(s.timer);
    for (const remove of s.listeners) remove();
    for (const bus of s.buses.values()) {
      bus.source.disconnect(); bus.gain.disconnect(); bus.audio.removeAttribute('src'); bus.audio.load();
    }
    s.buses.clear(); s.meter?.disconnect(); release(s.lease); s.label?.remove();
    s.video.pause();
    if (restore && s.baseline) s.baseline.gate.gain.value = 1;
    s.status = 'disposed';
  }
  function waitMedia(audio, event, predicate, milliseconds = 15000) {
    if (predicate()) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const finish = error => {
        clearTimeout(timer); audio.removeEventListener(event, check); audio.removeEventListener('error', failed);
        error ? reject(error) : resolve();
      };
      const check = () => { if (predicate()) finish(); };
      const failed = () => finish(new Error(`Source playback failed (${audio.error?.code || 'unknown'})`));
      const timer = setTimeout(() => finish(new Error(`Source ${event} timed out`)), milliseconds);
      audio.addEventListener(event, check); audio.addEventListener('error', failed);
    });
  }
  async function align(s) {
    if (!current(s) || s.status !== 'ready' || s.syncing) return;
    s.syncing = true;
    try {
      const running = !s.video.paused && !s.video.ended && !s.video.seeking;
      if (running) await context.resume();
      if (!current(s)) return;
      for (const bus of s.buses.values()) {
        const target = s.video.currentTime - bus.offset;
        bus.waiting = target < 0 || target >= bus.audio.duration;
        bus.audio.playbackRate = s.video.playbackRate;
        if (bus.waiting) { bus.audio.pause(); gain(s, bus); continue; }
        const drift = Math.abs(bus.audio.currentTime - target);
        s.maximumObservedDrift = Math.max(s.maximumObservedDrift, drift);
        if (drift > 0.03 || s.seeking) {
          bus.waiting = true; gain(s, bus); bus.audio.pause();
          bus.audio.currentTime = target;
          await waitMedia(bus.audio, 'seeked', () => !bus.audio.seeking);
          if (!current(s)) return;
          bus.waiting = false;
        }
      }
      s.seeking = s.video.seeking;
      const plays = [];
      for (const bus of s.buses.values()) {
        gain(s, bus);
        if (!s.video.paused && !s.video.ended && !s.seeking && !bus.waiting) plays.push(bus.audio.play());
        else bus.audio.pause();
      }
      await Promise.all(plays);
      if (!current(s) || s.video.paused || s.video.ended) pause(s);
    } catch (error) { fail(s, error); }
    finally { s.syncing = false; }
  }
  function update(s, streams) {
    s.streams = Array.isArray(streams) ? streams : [];
    const selected = new Map(s.streams.map(row => [row.index, row]));
    for (const [index, bus] of s.buses) {
      // A prepared bus without a matching original control must never be an
      // audible hidden master. Also fail closed during asynchronous UI loading.
      bus.muted = !selected.has(index) || selected.get(index).isMuted === true;
      gain(s, bus);
    }
  }
  async function attach({ uuid, path, video, streams }) {
    if (!uuid || !path || !video || !window.MedalIPC?.nativeAudioPreview) return;
    if (active?.uuid === uuid && active.path === path && active.video === video) { update(active, streams); return; }
    dispose(active);
    const s = active = { uuid, path, video, generation: ++generation, buses: new Map(), listeners: [],
      streams: streams || [], status: 'preparing', seeking: false, maximumObservedDrift: 0 };
    try {
      // A zero gain node is independent of the user's master mute/volume controls.
      s.baseline = baseline(video);
      s.meter = context.createAnalyser(); s.meter.fftSize = 2048; s.meter.connect(context.destination);
      s.label = document.createElement('div'); s.label.setAttribute('role', 'status');
      s.label.dataset.nativeAudioStatus = '';
      s.label.style.cssText = 'position:absolute;bottom:48px;left:12px;right:12px;z-index:1000;color:white;background:#222;padding:8px;pointer-events:none';
      video.parentElement?.appendChild(s.label);
      status(s, 'preparing', 'Preparing audio preview…');
      const listen = (name, fn) => { video.addEventListener(name, fn); s.listeners.push(() => video.removeEventListener(name, fn)); };
      listen('pause', () => pause(s)); listen('ended', () => pause(s));
      listen('seeking', () => { s.seeking = true; pause(s); gains(s); });
      for (const name of ['play', 'seeked', 'ratechange']) listen(name, () => align(s));
      listen('volumechange', () => gains(s));
      listen('emptied', () => { s.seeking = true; pause(s); gains(s); });
      const prepared = await window.MedalIPC.nativeAudioPreview.prepare({ uuid, path });
      if (!current(s)) { release(prepared.lease); return; }
      s.lease = prepared.lease;
      if (prepared.streams.length > 1 && prepared.streams.some(row =>
          row.title === 'All Audio' || row.logicalId === 'all-audio')) {
        throw new Error('Audition manifest contains a hidden master');
      }
      for (const stream of prepared.streams) {
        const audio = new Audio(); audio.preload = 'auto'; audio.crossOrigin = 'anonymous';
        const source = context.createMediaElementSource(audio), node = context.createGain();
        node.gain.value = 0; source.connect(node).connect(s.meter);
        const bus = { audio, source, gain: node, offset: stream.offset, muted: stream.isMuted, waiting: true };
        s.buses.set(stream.index, bus); audio.src = stream.url; audio.load();
        await waitMedia(audio, 'canplay', () => audio.readyState >= 3);
        if (!current(s)) return;
      }
      status(s, 'ready'); update(s, s.streams);
      if (restore?.uuid === uuid && restore.path === path) {
        const saved = restore; restore = null;
        video.currentTime = Math.max(0, Math.min(saved.time, video.duration || saved.time));
        if (saved.playing) await video.play();
      }
      await align(s);
      if (current(s)) s.timer = setInterval(() => align(s), 100);
    } catch (error) { fail(s, error); }
  }
  window.addEventListener('pagehide', () => dispose(active));
  window.NativeMedalAudioPreviewController = Object.freeze({ attach,
    detach: () => dispose(active),
    editCheckpoint: uuid => active?.uuid === uuid ? { time: active.video.currentTime, playing: !active.video.paused } : null,
    expectSaved: checkpoint => { restore = checkpoint; },
    snapshot: () => {
      if (!active) return { state: 'disposed' };
      const samples = new Float32Array(active.meter?.fftSize || 0); active.meter?.getFloatTimeDomainData(samples);
      return { state: active.status, buses: active.buses.size, baselineGain: active.baseline?.gate.gain.value,
        outputPeak: samples.reduce((peak, value) => Math.max(peak, Math.abs(value)), 0),
        maximumObservedDrift: active.maximumObservedDrift, muted: [...active.buses.values()].map(b => b.muted),
        busesState: [...active.buses.entries()].map(([index, b]) => ({ index, time: b.audio.currentTime, paused: b.audio.paused,
          gain: b.gain.gain.value, ready: b.audio.readyState, offset: b.offset })) };
    },
  });
})();
