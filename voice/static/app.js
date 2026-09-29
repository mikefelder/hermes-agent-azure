(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const canvas = $('face');
  const statusEl = $('status');
  const captionEl = $('caption');
  const talkBtn = $('btn-talk');
  const talkLabel = talkBtn.querySelector('.label');
  const stopBtn = $('btn-stop');
  const textForm = $('text-form');
  const textInput = $('text-input');
  const transcriptPanel = $('transcript');
  const transcriptList = $('transcript-list');
  const debugPanel = $('debug');
  const metricsEl = $('metrics');
  const eventsEl = $('events');
  const personaBtns = Array.from(document.querySelectorAll('button[data-persona]'));

  const face = window.Faces.create(canvas);
  const TARGET_RATE = 16000;
  const MIN_CLIP_SECONDS = 0.3;
  const MAX_CLIP_SECONDS = 60;
  const MAX_EVENTS = 50;

  let persona = localStorage.getItem('voice.persona') === 'tars' ? 'tars' : 'rocky';
  let ws = null;
  let backoff = 500;
  let greeted = false;
  let serverState = 'done';
  let pendingText = [];

  // ---------- UI helpers ----------
  function setStatus(text) { statusEl.textContent = text; }

  function logEvent(text, isErr = false) {
    const li = document.createElement('li');
    li.textContent = `${new Date().toLocaleTimeString()} ${text}`;
    if (isErr) li.className = 'err';
    eventsEl.prepend(li);
    while (eventsEl.children.length > MAX_EVENTS) eventsEl.lastChild.remove();
  }

  function addTranscript(role, text) {
    const li = document.createElement('li');
    li.className = role === 'user' ? 'user' : 'assistant';
    const who = document.createElement('span');
    who.className = 'who';
    who.textContent = role === 'user' ? 'You' : (persona === 'tars' ? 'TARS' : 'Rocky');
    li.append(who, document.createTextNode(' ' + text));
    transcriptList.append(li);
    transcriptList.scrollTop = transcriptList.scrollHeight;
  }

  function showMetrics(m) {
    metricsEl.replaceChildren();
    for (const [k, v] of Object.entries(m)) {
      if (k === 'type') continue;
      const dt = document.createElement('dt');
      dt.textContent = k;
      const dd = document.createElement('dd');
      dd.textContent = typeof v === 'number' ? `${v.toFixed(2)}s` : String(v);
      metricsEl.append(dt, dd);
    }
  }

  function applyPersona(key) {
    persona = key;
    localStorage.setItem('voice.persona', key);
    document.body.classList.toggle('tars', key === 'tars');
    for (const b of personaBtns) b.setAttribute('aria-checked', String(b.dataset.persona === key));
    face.setPersona(key);
  }

  function refreshFaceState() {
    if (recording) face.setState('listening');
    else if (player.active) face.setState('speaking');
    else if (serverState === 'thinking') face.setState('thinking');
    else face.setState('idle');

    if (recording) setStatus('Listening…');
    else if (player.active) setStatus('Speaking');
    else if (serverState === 'thinking') setStatus('Thinking…');
    else if (ws && ws.readyState === WebSocket.OPEN) setStatus('Hold space or the button to talk');
  }

  // ---------- Audio playback ----------
  let audioCtx = null;
  function ctx() {
    if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    if (audioCtx.state === 'suspended') audioCtx.resume().catch(() => {});
    return audioCtx;
  }

  const player = {
    queue: [],
    active: false,
    generation: 0,
    source: null,
    analyser: null,
    raf: 0,

    enqueue(buf, text) {
      const gen = this.generation;
      ctx().decodeAudioData(buf.slice(0)).then((audio) => {
        if (gen !== this.generation) return;
        this.queue.push({ audio, text });
        if (!this.active) this.next();
      }).catch((e) => logEvent(`decode failed: ${e}`, true));
    },

    next() {
      const item = this.queue.shift();
      if (!item) {
        this.active = false;
        this.stopMeter();
        captionEl.textContent = '';
        refreshFaceState();
        return;
      }
      const c = ctx();
      if (!this.analyser) {
        this.analyser = c.createAnalyser();
        this.analyser.fftSize = 512;
        this.analyser.connect(c.destination);
      }
      const src = c.createBufferSource();
      src.buffer = item.audio;
      src.connect(this.analyser);
      const gen = this.generation;
      src.onended = () => { if (gen === this.generation) this.next(); };
      this.source = src;
      this.active = true;
      captionEl.textContent = item.text || '';
      refreshFaceState();
      this.startMeter();
      src.start();
    },

    flush() {
      this.generation++;
      this.queue = [];
      if (this.source) {
        try { this.source.onended = null; this.source.stop(); } catch (_) { /* already stopped */ }
        this.source = null;
      }
      this.active = false;
      this.stopMeter();
      captionEl.textContent = '';
      pendingText = [];
      refreshFaceState();
    },

    startMeter() {
      if (this.raf) return;
      const data = new Float32Array(this.analyser.fftSize);
      const tick = () => {
        this.analyser.getFloatTimeDomainData(data);
        let sum = 0;
        for (let i = 0; i < data.length; i++) sum += data[i] * data[i];
        face.setLevel(Math.min(1, Math.sqrt(sum / data.length) * 4));
        this.raf = requestAnimationFrame(tick);
      };
      this.raf = requestAnimationFrame(tick);
    },

    stopMeter() {
      if (this.raf) cancelAnimationFrame(this.raf);
      this.raf = 0;
      face.setLevel(0);
    },
  };

  // ---------- WebSocket ----------
  function send(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
  }

  function connect() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    ws = new WebSocket(`${proto}//${location.host}/ws`);
    ws.binaryType = 'arraybuffer';
    setStatus('Connecting…');

    ws.onopen = () => {
      backoff = 500;
      logEvent('connected');
      send({ type: 'hello', persona, greet: !greeted });
      greeted = true;
      refreshFaceState();
    };

    ws.onclose = () => {
      logEvent('disconnected', true);
      setStatus('Reconnecting…');
      serverState = 'done';
      player.flush();
      setTimeout(connect, backoff);
      backoff = Math.min(backoff * 2, 10000);
    };

    ws.onerror = () => { /* onclose handles retry */ };

    ws.onmessage = (ev) => {
      if (ev.data instanceof ArrayBuffer) {
        player.enqueue(ev.data, pendingText.shift() || '');
        return;
      }
      let msg;
      try { msg = JSON.parse(ev.data); } catch (_) { return; }
      switch (msg.type) {
        case 'persona':
          if (msg.persona !== persona) applyPersona(msg.persona);
          logEvent(`persona ${msg.name}`);
          break;
        case 'state':
          if (msg.state === 'thinking' && serverState !== 'thinking') player.flush();
          serverState = msg.state;
          refreshFaceState();
          break;
        case 'emotion':
          face.setEmotion(msg.emotion);
          break;
        case 'transcript':
          addTranscript(msg.role, msg.text);
          break;
        case 'speak_begin':
          pendingText.push(msg.text);
          break;
        case 'metrics':
          showMetrics(msg);
          logEvent(`turn route=${msg.route ?? '?'} ttfa=${msg.ttfa ?? '?'}`);
          break;
        case 'error':
          logEvent(`error: ${msg.message}`, true);
          setStatus('Something went wrong');
          break;
        default:
          break;
      }
    };
  }

  // ---------- Microphone ----------
  let recording = false;
  let micStream = null;
  let micNode = null;
  let micSource = null;
  let micFrames = [];
  let micRate = 48000;
  let workletLoaded = false;

  async function startRecording() {
    if (recording) return;
    if (!navigator.mediaDevices || !window.isSecureContext) {
      logEvent('microphone requires HTTPS or localhost', true);
      setStatus('Mic unavailable (needs HTTPS)');
      return;
    }
    recording = true;
    talkBtn.classList.add('recording');
    talkLabel.textContent = 'Transmitting…';
    player.flush();
    send({ type: 'cancel' });
    refreshFaceState();
    try {
      const c = ctx();
      if (!workletLoaded) {
        await c.audioWorklet.addModule('/static/mic-worklet.js');
        workletLoaded = true;
      }
      micStream = micStream || await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      });
      if (!recording) return;
      micRate = c.sampleRate;
      micFrames = [];
      micSource = c.createMediaStreamSource(micStream);
      micNode = new AudioWorkletNode(c, 'mic-capture');
      micNode.port.onmessage = (e) => {
        micFrames.push(e.data);
        let sum = 0;
        for (let i = 0; i < e.data.length; i++) sum += e.data[i] * e.data[i];
        face.setLevel(Math.min(1, Math.sqrt(sum / e.data.length) * 6));
      };
      micSource.connect(micNode);
    } catch (e) {
      logEvent(`mic error: ${e.message || e}`, true);
      recording = false;
      talkBtn.classList.remove('recording');
      talkLabel.textContent = 'Hold to talk';
      refreshFaceState();
    }
  }

  function stopRecording() {
    if (!recording) return;
    recording = false;
    talkBtn.classList.remove('recording');
    talkLabel.textContent = 'Hold to talk';
    face.setLevel(0);
    if (micNode) {
      micNode.port.postMessage('stop');
      micNode.port.onmessage = null;
      try { micSource.disconnect(); micNode.disconnect(); } catch (_) { /* ignore */ }
      micNode = null;
      micSource = null;
    }
    const frames = micFrames;
    micFrames = [];
    refreshFaceState();

    const total = frames.reduce((n, f) => n + f.length, 0);
    const seconds = total / micRate;
    if (seconds < MIN_CLIP_SECONDS) {
      logEvent('clip too short, ignored');
      return;
    }
    const merged = new Float32Array(Math.min(total, Math.floor(MAX_CLIP_SECONDS * micRate)));
    let off = 0;
    for (const f of frames) {
      if (off >= merged.length) break;
      const n = Math.min(f.length, merged.length - off);
      merged.set(n === f.length ? f : f.subarray(0, n), off);
      off += n;
    }
    const wav = encodeWav(downsample(merged, micRate, TARGET_RATE), TARGET_RATE);
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(wav);
      serverState = 'thinking';
      refreshFaceState();
      logEvent(`sent ${seconds.toFixed(1)}s audio`);
    } else {
      logEvent('not connected', true);
    }
  }

  function downsample(input, fromRate, toRate) {
    if (fromRate === toRate) return input;
    const ratio = fromRate / toRate;
    const out = new Float32Array(Math.floor(input.length / ratio));
    for (let i = 0; i < out.length; i++) {
      const start = Math.floor(i * ratio);
      const end = Math.min(input.length, Math.floor((i + 1) * ratio));
      let sum = 0;
      for (let j = start; j < end; j++) sum += input[j];
      out[i] = end > start ? sum / (end - start) : 0;
    }
    return out;
  }

  function encodeWav(samples, rate) {
    const buf = new ArrayBuffer(44 + samples.length * 2);
    const v = new DataView(buf);
    const str = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
    str(0, 'RIFF'); v.setUint32(4, 36 + samples.length * 2, true); str(8, 'WAVE');
    str(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
    v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
    str(36, 'data'); v.setUint32(40, samples.length * 2, true);
    for (let i = 0, o = 44; i < samples.length; i++, o += 2) {
      const s = Math.max(-1, Math.min(1, samples[i]));
      v.setInt16(o, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    }
    return buf;
  }

  // ---------- Controls ----------
  function cancel() {
    player.flush();
    send({ type: 'cancel' });
    logEvent('cancelled');
  }

  talkBtn.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    talkBtn.setPointerCapture(e.pointerId);
    startRecording();
  });
  talkBtn.addEventListener('pointerup', stopRecording);
  talkBtn.addEventListener('pointercancel', stopRecording);
  talkBtn.addEventListener('contextmenu', (e) => e.preventDefault());

  stopBtn.addEventListener('click', cancel);

  textForm.addEventListener('submit', (e) => {
    e.preventDefault();
    const text = textInput.value.trim();
    if (!text) return;
    ctx();
    player.flush();
    send({ type: 'text', text });
    serverState = 'thinking';
    refreshFaceState();
    textInput.value = '';
  });

  for (const b of personaBtns) {
    b.addEventListener('click', () => {
      const key = b.dataset.persona;
      if (key === persona) return;
      ctx();
      player.flush();
      applyPersona(key);
      send({ type: 'persona', persona: key });
    });
  }

  function toggleLog() {
    const hidden = document.body.classList.toggle('log-hidden');
    $('btn-transcript').setAttribute('aria-expanded', String(!hidden));
    window.dispatchEvent(new Event('resize'));
  }
  function toggleDebug() {
    debugPanel.hidden = !debugPanel.hidden;
    $('btn-debug').setAttribute('aria-expanded', String(!debugPanel.hidden));
  }
  function setFace(on) {
    document.body.classList.toggle('face-hidden', !on);
    $('btn-face').setAttribute('aria-expanded', String(on));
    localStorage.setItem('voice.face', on ? 'on' : 'off');
    window.dispatchEvent(new Event('resize'));
  }
  function toggleFace() {
    setFace(document.body.classList.contains('face-hidden'));
  }
  setFace(localStorage.getItem('voice.face') === 'on');
  $('btn-face').addEventListener('click', toggleFace);
  $('btn-transcript').addEventListener('click', toggleLog);
  $('btn-debug').addEventListener('click', toggleDebug);

  const typing = () => document.activeElement === textInput;
  window.addEventListener('keydown', (e) => {
    if (typing()) {
      if (e.key === 'Escape') textInput.blur();
      return;
    }
    if (e.code === 'Space') {
      e.preventDefault();
      if (!e.repeat) startRecording();
    } else if (e.key === 'Escape') {
      cancel();
    } else if (e.key === 'd' || e.key === 'D') {
      toggleDebug();
    } else if (e.key === 'f' || e.key === 'F') {
      toggleFace();
    }
  });
  window.addEventListener('keyup', (e) => {
    if (e.code === 'Space' && !typing()) { e.preventDefault(); stopRecording(); }
  });
  window.addEventListener('blur', stopRecording);
  // Browsers block audio until a user gesture; unlock on the first one.
  window.addEventListener('pointerdown', () => ctx(), { once: true });

  applyPersona(persona);
  connect();
})();
