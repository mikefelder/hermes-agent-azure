// Canvas faces for Rocky (Eridian carapace) and TARS (monolith panels).
// API: const f = Faces.create(canvas); f.setPersona('rocky'|'tars');
//      f.setEmotion(name); f.setState('idle'|'listening'|'thinking'|'speaking'); f.setLevel(0..1)
(function () {
  'use strict';

  // Per-emotion targets. Rocky: plate spread, plate lift, rotation speed, droop, jitter, glow.
  // TARS: per-panel vertical offsets (fraction of height), slide, readout speed, meter.
  const ROCKY = {
    neutral:   { spread: 1.00, lift: 0.00, spin: 0.10, droop: 0.0, jitter: 0.0, glow: 0.55 },
    happy:     { spread: 1.12, lift: 0.10, spin: 0.35, droop: 0.0, jitter: 0.0, glow: 0.85 },
    sad:       { spread: 0.86, lift: -0.08, spin: 0.03, droop: 0.35, jitter: 0.0, glow: 0.30 },
    angry:     { spread: 0.92, lift: 0.04, spin: 0.60, droop: 0.0, jitter: 0.6, glow: 0.95 },
    surprised: { spread: 1.28, lift: 0.18, spin: 0.15, droop: 0.0, jitter: 0.1, glow: 1.00 },
    sleepy:    { spread: 0.90, lift: -0.04, spin: 0.02, droop: 0.20, jitter: 0.0, glow: 0.20 },
    thinking:  { spread: 0.96, lift: 0.02, spin: 0.25, droop: 0.05, jitter: 0.0, glow: 0.60 },
  };
  const TARS = {
    neutral:   { offs: [0, 0, 0, 0],               slide: 0.00, speed: 1.0, meter: 0.75 },
    happy:     { offs: [-0.02, 0.02, -0.02, 0.02], slide: 0.02, speed: 1.6, meter: 0.95 },
    sad:       { offs: [0.03, 0.04, 0.04, 0.03],   slide: 0.00, speed: 0.4, meter: 0.40 },
    angry:     { offs: [0.00, -0.05, -0.05, 0.00], slide: 0.00, speed: 2.4, meter: 0.20 },
    surprised: { offs: [-0.05, 0.00, 0.00, -0.05], slide: 0.05, speed: 2.0, meter: 0.60 },
    sleepy:    { offs: [0.05, 0.05, 0.05, 0.05],   slide: 0.00, speed: 0.2, meter: 0.30 },
    thinking:  { offs: [0.00, -0.02, 0.02, 0.00],  slide: 0.01, speed: 1.2, meter: 0.70 },
  };

  const approach = (cur, tgt, k) => cur + (tgt - cur) * k;

  function create(canvas) {
    const ctx = canvas.getContext('2d');
    let persona = 'rocky';
    let emotion = 'neutral';
    let state = 'idle';
    let level = 0;       // smoothed speech level
    let rawLevel = 0;
    let dpr = 1, W = 0, H = 0;
    const r = Object.assign({}, ROCKY.neutral);
    const t = { offs: [0, 0, 0, 0], slide: 0, speed: 1, meter: 0.75 };
    const ripples = [];
    let readout = [];
    let readoutScroll = 0;
    let last = performance.now();
    let blinkUntil = 0;

    function resize() {
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = canvas.clientWidth; H = canvas.clientHeight;
      canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    window.addEventListener('resize', resize);
    resize();

    function readoutLine() {
      const words = ['NAV', 'O2', 'CUE', 'HUM', 'HON', 'ENG', 'LNK', 'GRV', 'TMP', 'SYS'];
      const w = words[(Math.random() * words.length) | 0];
      return `${w} ${(Math.random() * 999).toFixed(0).padStart(3, '0')}.${(Math.random() * 99).toFixed(0).padStart(2, '0')}`;
    }
    for (let i = 0; i < 24; i++) readout.push(readoutLine());

    // ---------------- Rocky ----------------
    function drawRocky(now, dt) {
      const tg = ROCKY[emotion] || ROCKY.neutral;
      for (const k in tg) r[k] = approach(r[k], tg[k], 0.25 * dt * 60 / 10 + 0.02);

      const cx = W / 2, cy = H / 2 - H * 0.03;
      const R = Math.min(W, H) * 0.2;
      const s = now / 1000;

      ctx.fillStyle = '#050507';
      ctx.fillRect(0, 0, W, H);

      // Ambient glow.
      const g = ctx.createRadialGradient(cx, cy, R * 0.2, cx, cy, R * 3);
      g.addColorStop(0, `rgba(255,74,61,${0.10 + r.glow * 0.12 + level * 0.15})`);
      g.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, W, H);

      // Speech ripples.
      if (state === 'speaking' && level > 0.12 && Math.random() < level * 0.5) {
        ripples.push({ r: R * 0.9, a: 0.5 * level });
      }
      for (let i = ripples.length - 1; i >= 0; i--) {
        const p = ripples[i];
        p.r += dt * R * 1.1; p.a -= dt * 0.45;
        if (p.a <= 0) { ripples.splice(i, 1); continue; }
        ctx.strokeStyle = `rgba(242,180,92,${p.a})`;
        ctx.lineWidth = 2;
        ctx.beginPath(); ctx.arc(cx, cy, p.r, 0, Math.PI * 2); ctx.stroke();
      }

      const breathe = Math.sin(s * 1.3) * 0.02;
      const spread = r.spread + breathe + level * 0.18;
      const rot = s * r.spin;

      // Five carapace plates.
      for (let i = 0; i < 5; i++) {
        const base = rot + (i / 5) * Math.PI * 2 - Math.PI / 2;
        const droop = Math.sin(base) > 0 ? r.droop * 0.25 : 0;
        const jx = (Math.random() - 0.5) * r.jitter * 4;
        const jy = (Math.random() - 0.5) * r.jitter * 4;
        const a0 = base - 0.52, a1 = base + 0.52;
        const inner = R * 0.35 * spread;
        const outer = R * (1.0 + r.lift) * spread;
        const ox = Math.cos(base) * R * 0.08 * (spread - 0.9) + jx;
        const oy = Math.sin(base) * R * 0.08 * (spread - 0.9) + jy + droop * R;

        ctx.beginPath();
        ctx.moveTo(cx + ox + Math.cos(a0) * inner, cy + oy + Math.sin(a0) * inner);
        ctx.lineTo(cx + ox + Math.cos(a0 + 0.06) * outer, cy + oy + Math.sin(a0 + 0.06) * outer);
        ctx.quadraticCurveTo(
          cx + ox + Math.cos(base) * outer * 1.12, cy + oy + Math.sin(base) * outer * 1.12,
          cx + ox + Math.cos(a1 - 0.06) * outer, cy + oy + Math.sin(a1 - 0.06) * outer);
        ctx.lineTo(cx + ox + Math.cos(a1) * inner, cy + oy + Math.sin(a1) * inner);
        ctx.closePath();
        const pg = ctx.createLinearGradient(cx, cy, cx + Math.cos(base) * outer, cy + Math.sin(base) * outer);
        pg.addColorStop(0, '#2a1512');
        pg.addColorStop(1, `rgba(${150 + r.glow * 80},${70 + r.glow * 30},50,1)`);
        ctx.fillStyle = pg;
        ctx.fill();
        ctx.strokeStyle = `rgba(242,180,92,${0.25 + r.glow * 0.4})`;
        ctx.lineWidth = 1.5;
        ctx.stroke();
      }

      // Core vent: pulses with speech (Rocky "sings").
      const coreR = R * (0.22 + level * 0.12 + Math.sin(s * 2) * 0.01);
      const cg = ctx.createRadialGradient(cx, cy, 0, cx, cy, coreR);
      cg.addColorStop(0, `rgba(255,${200 - level * 80},140,${0.6 + level * 0.4})`);
      cg.addColorStop(1, 'rgba(255,74,61,0)');
      ctx.fillStyle = cg;
      ctx.beginPath(); ctx.arc(cx, cy, coreR * 1.6, 0, Math.PI * 2); ctx.fill();

      // Thinking: orbiting dots.
      if (state === 'thinking') {
        for (let i = 0; i < 3; i++) {
          const a = s * 2.4 + i * (Math.PI * 2 / 3);
          ctx.fillStyle = '#f2b45c';
          ctx.beginPath();
          ctx.arc(cx + Math.cos(a) * R * 1.45, cy + Math.sin(a) * R * 1.45, 4, 0, Math.PI * 2);
          ctx.fill();
        }
      }
      // Listening: steady ring.
      if (state === 'listening') {
        ctx.strokeStyle = `rgba(255,74,61,${0.5 + Math.sin(s * 6) * 0.2})`;
        ctx.lineWidth = 2;
        ctx.beginPath(); ctx.arc(cx, cy, R * 1.35, 0, Math.PI * 2); ctx.stroke();
      }
    }

    // ---------------- TARS ----------------
    function drawTars(now, dt) {
      const tg = TARS[emotion] || TARS.neutral;
      const k = 0.25 * dt * 60 / 10 + 0.02;
      for (let i = 0; i < 4; i++) t.offs[i] = approach(t.offs[i], tg.offs[i], k);
      t.slide = approach(t.slide, tg.slide, k);
      t.speed = approach(t.speed, tg.speed, k);
      t.meter = approach(t.meter, tg.meter, k);
      const s = now / 1000;

      ctx.fillStyle = '#0b0c0d';
      ctx.fillRect(0, 0, W, H);

      const bh = Math.min(H * 0.62, W * 1.1);
      const pw = bh * 0.14;
      const gap = pw * 0.06;
      const totalW = pw * 4 + gap * 3;
      const x0 = W / 2 - totalW / 2;
      const y0 = H / 2 - bh / 2 - H * 0.03;

      for (let i = 0; i < 4; i++) {
        const talk = state === 'speaking' ? Math.sin(s * 14 + i * 1.7) * level * 0.012 : 0;
        const dy = (t.offs[i] + talk) * bh;
        const dx = (i < 2 ? -1 : 1) * t.slide * pw;
        const x = x0 + i * (pw + gap) + dx;
        const y = y0 + dy;

        const pg = ctx.createLinearGradient(x, 0, x + pw, 0);
        pg.addColorStop(0, '#3a3d42');
        pg.addColorStop(0.5, '#5b5f66');
        pg.addColorStop(1, '#34373b');
        ctx.fillStyle = pg;
        ctx.fillRect(x, y, pw, bh);
        ctx.strokeStyle = 'rgba(0,0,0,0.6)';
        ctx.lineWidth = 1;
        for (let j = 1; j < 6; j++) {
          ctx.beginPath(); ctx.moveTo(x + 2, y + (bh * j) / 6); ctx.lineTo(x + pw - 2, y + (bh * j) / 6); ctx.stroke();
        }
      }

      // Readout screen on panel 2.
      const sx = x0 + (pw + gap) + (-t.slide * pw) + pw * 0.1;
      const sy = y0 + t.offs[1] * bh + bh * 0.12;
      const sw = pw * 0.8, sh = bh * 0.3;
      ctx.fillStyle = '#0a1210';
      ctx.fillRect(sx, sy, sw, sh);
      ctx.save();
      ctx.beginPath(); ctx.rect(sx, sy, sw, sh); ctx.clip();
      const lh = Math.max(9, sw * 0.14);
      ctx.font = `${lh * 0.8}px ui-monospace, Menlo, monospace`;
      readoutScroll += dt * lh * t.speed * (state === 'thinking' ? 3 : 1);
      while (readoutScroll > lh) { readoutScroll -= lh; readout.shift(); readout.push(readoutLine()); }
      const bright = 0.45 + level * 0.55;
      ctx.fillStyle = `rgba(150,255,190,${bright})`;
      for (let i = 0; i < readout.length; i++) {
        const yy = sy + i * lh - readoutScroll + lh;
        if (yy > sy + sh + lh) break;
        ctx.fillText(readout[i], sx + 3, yy);
      }
      // Scan bar while thinking.
      if (state === 'thinking') {
        const by = sy + ((s * 0.8) % 1) * sh;
        ctx.fillStyle = 'rgba(150,255,190,0.25)';
        ctx.fillRect(sx, by, sw, 3);
      }
      ctx.restore();

      // Voice level bar on panel 3.
      const vx = x0 + 2 * (pw + gap) + t.slide * pw + pw * 0.3;
      const vy = y0 + t.offs[2] * bh + bh * 0.12;
      const vh = bh * 0.3, vw = pw * 0.4;
      ctx.fillStyle = '#111';
      ctx.fillRect(vx, vy, vw, vh);
      const lv = state === 'listening' ? 0.3 + Math.sin(s * 6) * 0.1 : level;
      ctx.fillStyle = state === 'listening' ? '#e0a040' : '#c8ccd2';
      ctx.fillRect(vx, vy + vh * (1 - lv), vw, vh * lv);

      // Humor / honesty meter across the bottom.
      const mx = x0, my = y0 + bh + H * 0.04, mw = totalW, mh = 6;
      ctx.fillStyle = '#222';
      ctx.fillRect(mx, my, mw, mh);
      ctx.fillStyle = '#c8ccd2';
      ctx.fillRect(mx, my, mw * t.meter, mh);
      ctx.fillStyle = '#7b8290';
      ctx.font = '11px ui-monospace, Menlo, monospace';
      ctx.fillText(`HUMOR ${Math.round(t.meter * 100)}%`, mx, my + 20);
      ctx.fillText('HONESTY 90%', mx + mw - 78, my + 20);

      // Idle blink of the readout (occasional).
      if (now > blinkUntil && Math.random() < 0.002) blinkUntil = now + 120;
      if (now < blinkUntil) { ctx.fillStyle = '#0a1210'; ctx.fillRect(sx, sy, sw, sh); }
    }

    function frame(now) {
      const dt = Math.min(0.1, (now - last) / 1000);
      last = now;
      level = approach(level, rawLevel, rawLevel > level ? 0.5 : 0.15);
      if (persona === 'tars') drawTars(now, dt); else drawRocky(now, dt);
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);

    return {
      setPersona(p) { persona = p === 'tars' ? 'tars' : 'rocky'; ripples.length = 0; },
      setEmotion(e) { emotion = (ROCKY[e] ? e : 'neutral'); },
      setState(s) { state = s; },
      setLevel(l) { rawLevel = Math.max(0, Math.min(1, l)); },
    };
  }

  window.Faces = { create };
})();
