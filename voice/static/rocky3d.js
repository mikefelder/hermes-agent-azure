// Rocky 3D "video call" renderer. Registers a factory with faces.js; rendering
// happens only inside frame() driven by the 2D face loop.
import * as THREE from 'three';

const MODEL_URL = '/static/models/rocky.bin';

const EMO = {
  neutral:   { bob: 1.0, sway: 1.0, legs: 1.0, tint: 0x9aa3a8, lift: 0.00 },
  happy:     { bob: 1.6, sway: 1.4, legs: 1.8, tint: 0xb0a890, lift: 0.02 },
  sad:       { bob: 0.5, sway: 0.5, legs: 0.4, tint: 0x7f8a94, lift: -0.03 },
  angry:     { bob: 1.2, sway: 0.4, legs: 2.2, tint: 0xa88a80, lift: 0.01 },
  surprised: { bob: 0.6, sway: 0.3, legs: 2.6, tint: 0xa9adb0, lift: 0.04 },
  sleepy:    { bob: 0.3, sway: 0.6, legs: 0.2, tint: 0x80868c, lift: -0.04 },
  thinking:  { bob: 0.7, sway: 1.8, legs: 0.8, tint: 0x94a0a6, lift: 0.00 },
};

function parseModel(buf) {
  const dv = new DataView(buf);
  const magic = String.fromCharCode(dv.getUint8(0), dv.getUint8(1), dv.getUint8(2), dv.getUint8(3));
  if (magic !== 'RKY1') throw new Error('bad rocky.bin magic');
  const nv = dv.getUint32(4, true);
  const nt = dv.getUint32(8, true);
  const pos = new Float32Array(buf, 12, nv * 3);
  const idx = new Uint32Array(buf, 12 + nv * 12, nt * 3);
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  g.setIndex(new THREE.BufferAttribute(idx, 1));
  g.computeVertexNormals();
  g.computeBoundingSphere();
  return g;
}

// Crude stand-in (carapace + five legs) shown until the real model loads.
function fallbackGeometry() {
  const parts = [];
  const body = new THREE.SphereGeometry(0.28, 32, 20);
  body.scale(1, 0.7, 1);
  body.translate(0, 0.62, 0);
  parts.push(body);
  for (let i = 0; i < 5; i++) {
    const a = (i / 5) * Math.PI * 2 + Math.PI / 2;
    const upper = new THREE.CylinderGeometry(0.045, 0.06, 0.42, 10);
    upper.rotateZ(-0.9);
    upper.translate(0.3, 0.72, 0);
    upper.rotateY(a);
    const lower = new THREE.CylinderGeometry(0.03, 0.045, 0.62, 10);
    lower.rotateZ(0.25);
    lower.translate(0.55, 0.31, 0);
    lower.rotateY(a);
    parts.push(upper, lower);
  }
  // merge manually (avoids BufferGeometryUtils import)
  const positions = [];
  const indices = [];
  let off = 0;
  for (const p of parts) {
    const pa = p.attributes.position.array;
    for (let i = 0; i < pa.length; i++) positions.push(pa[i]);
    const ia = p.index.array;
    for (let i = 0; i < ia.length; i++) indices.push(ia[i] + off);
    off += pa.length / 3;
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  g.setIndex(indices);
  g.computeVertexNormals();
  return g;
}

function makeMaterial(uniforms) {
  const mat = new THREE.MeshStandardMaterial({
    color: 0x9aa3a8,
    roughness: 0.82,
    metalness: 0.08,
    flatShading: false,
  });
  mat.onBeforeCompile = (shader) => {
    Object.assign(shader.uniforms, uniforms);
    shader.vertexShader = shader.vertexShader
      .replace('#include <common>', `#include <common>
uniform float uTime;
uniform float uLegAmp;
uniform float uLevel;
varying float vHeight;`)
      .replace('#include <begin_vertex>', `#include <begin_vertex>
{
  float r = length(position.xz);
  float ang = atan(position.z, position.x);
  // legs: far from the centre axis; carapace stays rigid
  float legW = smoothstep(0.22, 0.6, r);
  float phase = ang * 5.0;
  float wave = sin(uTime * 2.3 + phase) * 0.5 + sin(uTime * 5.1 + phase * 0.7) * 0.25 * uLevel;
  transformed.y += wave * uLegAmp * 0.035 * legW;
  transformed.xz *= 1.0 + wave * uLegAmp * 0.012 * legW;
  // carapace swells slightly with speech energy
  float shell = 1.0 - smoothstep(0.15, 0.35, r);
  transformed += normal * shell * uLevel * 0.006;
}
vHeight = position.y;`);
    shader.fragmentShader = shader.fragmentShader
      .replace('#include <common>', `#include <common>
uniform vec3 uGlow;
uniform float uGlowAmt;
varying float vHeight;`)
      .replace('#include <emissivemap_fragment>', `#include <emissivemap_fragment>
totalEmissiveRadiance += uGlow * uGlowAmt * smoothstep(0.45, 0.8, vHeight);`);
  };
  return mat;
}

function factory(host) {
  const canvas = document.createElement('canvas');
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false, powerPreference: 'low-power' });
  if (!renderer.getContext()) throw new Error('no webgl');
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  renderer.setClearColor(0x05080a, 1);
  host.appendChild(canvas);

  const scene = new THREE.Scene();
  scene.fog = new THREE.Fog(0x05080a, 2.6, 5.5);

  const camera = new THREE.PerspectiveCamera(32, 1, 0.05, 20);
  const camTarget = new THREE.Vector3(0, 0.45, 0);

  scene.add(new THREE.HemisphereLight(0x3a5560, 0x0b0806, 0.55));
  const key = new THREE.DirectionalLight(0xffb86b, 2.4);
  key.position.set(1.6, 2.4, 1.8);
  scene.add(key);
  const rim = new THREE.DirectionalLight(0x4fd6d0, 1.6);
  rim.position.set(-2.0, 1.2, -1.6);
  scene.add(rim);
  const fill = new THREE.PointLight(0xff9a4a, 0.6, 4);
  fill.position.set(0, 0.2, 1.4);
  scene.add(fill);

  // Xenonite-ish floor disc with grid glow
  const floor = new THREE.Mesh(
    new THREE.CircleGeometry(1.6, 64),
    new THREE.MeshStandardMaterial({ color: 0x0d1215, roughness: 0.95, metalness: 0.0 })
  );
  floor.rotation.x = -Math.PI / 2;
  scene.add(floor);
  const grid = new THREE.PolarGridHelper(1.5, 10, 6, 64, 0x1f4a4a, 0x163333);
  grid.position.y = 0.001;
  grid.material.transparent = true;
  grid.material.opacity = 0.45;
  scene.add(grid);

  const uniforms = {
    uTime: { value: 0 },
    uLegAmp: { value: 1 },
    uLevel: { value: 0 },
    uGlow: { value: new THREE.Color(0xff9a3c) },
    uGlowAmt: { value: 0 },
  };
  const material = makeMaterial(uniforms);
  const rig = new THREE.Group();
  scene.add(rig);
  let mesh = new THREE.Mesh(fallbackGeometry(), material);
  rig.add(mesh);

  fetch(MODEL_URL)
    .then((r) => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.arrayBuffer(); })
    .then((buf) => {
      const g = parseModel(buf);
      const old = mesh.geometry;
      mesh.geometry = g;
      old.dispose();
      host.dataset.model = 'loaded';
    })
    .catch((e) => { console.warn('rocky3d: model unavailable, using fallback', e); host.dataset.model = 'fallback'; });

  const hud = {
    clock: document.getElementById('hud-clock'),
    state: document.getElementById('hud-state'),
    freq: document.getElementById('hud-freq'),
    lag: document.getElementById('hud-lag'),
    sig: Array.from(document.querySelectorAll('#hud .sig i')),
  };
  const t0 = performance.now();

  let w = 0, h = 0;
  const resize = () => {
    const r = host.getBoundingClientRect();
    w = Math.max(1, Math.floor(r.width));
    h = Math.max(1, Math.floor(r.height));
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    // keep the whole body in frame on portrait screens
    camera.fov = camera.aspect < 1 ? 32 / Math.max(camera.aspect, 0.55) : 32;
    camera.updateProjectionMatrix();
  };
  const ro = new ResizeObserver(resize);
  ro.observe(host);
  resize();

  const s = { level: 0, bob: 1, sway: 1, legs: 1, lift: 0, glow: 0, yaw: 0, lean: 0, color: new THREE.Color(0x9aa3a8) };
  const tint = new THREE.Color();
  let active = false;
  let hudTick = 0;
  let lagMs = 40;

  function frame(now, dt, { state = 'idle', emotion = 'neutral', level = 0 } = {}) {
    if (!active) return;
    dt = Math.min(dt || 0.016, 0.1);
    const t = now / 1000;
    const e = EMO[emotion] || EMO.neutral;
    const k = 1 - Math.exp(-dt * 4);

    s.level += ((state === 'speaking' ? level : level * 0.4) - s.level) * (1 - Math.exp(-dt * 14));
    s.bob += (e.bob - s.bob) * k;
    s.sway += (e.sway - s.sway) * k;
    s.legs += (e.legs * (state === 'speaking' ? 1.3 : state === 'thinking' ? 0.6 : 1) - s.legs) * k;
    s.lift += (e.lift - s.lift) * k;
    s.color.lerp(tint.setHex(e.tint), k);
    const glowT = state === 'speaking' ? 0.15 + s.level * 0.9 : state === 'listening' ? 0.12 : state === 'thinking' ? 0.08 + 0.06 * Math.sin(t * 3) : 0.02;
    s.glow += (glowT - s.glow) * (1 - Math.exp(-dt * 10));

    // Listening: lean toward the camera; thinking: slow turn
    const yawT = state === 'thinking' ? Math.sin(t * 0.6) * 0.35 : Math.sin(t * 0.23) * 0.12 * s.sway;
    const leanT = state === 'listening' ? 0.08 : 0;
    s.yaw += (yawT - s.yaw) * k;
    s.lean += (leanT - s.lean) * k;

    uniforms.uTime.value = t;
    uniforms.uLegAmp.value = s.legs;
    uniforms.uLevel.value = s.level;
    uniforms.uGlowAmt.value = s.glow;
    material.color.copy(s.color);

    const breathe = Math.sin(t * 1.6) * 0.006 * s.bob;
    const speakBounce = s.level * 0.02 * Math.abs(Math.sin(t * 11));
    rig.position.y = s.lift + breathe + speakBounce;
    rig.rotation.y = s.yaw;
    rig.rotation.x = s.lean + Math.sin(t * 0.9) * 0.01 * s.sway;
    rig.rotation.z = Math.sin(t * 0.7) * 0.015 * s.sway;
    rig.scale.setScalar(1 + s.level * 0.012);

    // handheld-camera drift, slight push-in while speaking
    const dist = 3.4 - s.level * 0.12 - (state === 'listening' ? 0.1 : 0);
    camera.position.set(
      Math.sin(t * 0.17) * 0.12,
      0.72 + Math.sin(t * 0.23) * 0.03,
      dist
    );
    camera.lookAt(camTarget);
    fill.intensity = 0.4 + s.level * 1.4;

    renderer.render(scene, camera);

    hudTick += dt;
    if (hudTick > 0.25) {
      hudTick = 0;
      const el = Math.floor((now - t0) / 1000);
      if (hud.clock) hud.clock.textContent = [el / 3600, (el / 60) % 60, el % 60].map((x) => String(Math.floor(x)).padStart(2, '0')).join(':');
      if (hud.state) hud.state.textContent = ({ idle: 'LINK STABLE', listening: 'RX // HUMAN', thinking: 'TRANSLATING…', speaking: 'TX // ERIDIAN' })[state] || state.toUpperCase();
      if (hud.freq) hud.freq.textContent = (180 + s.level * 1400 + Math.random() * 20).toFixed(0);
      lagMs += (38 + Math.random() * 30 - lagMs) * 0.3;
      if (hud.lag) hud.lag.textContent = lagMs.toFixed(0);
      const bars = state === 'thinking' ? 3 + Math.round(Math.random()) : 4 + Math.round(Math.random());
      hud.sig.forEach((b, i) => b.classList.toggle('on', i < bars));
    }
  }

  function setActive(on) {
    active = !!on;
    host.style.display = active ? 'block' : 'none';
    if (active) resize();
  }

  return { frame, setActive };
}

if (window.Faces && window.Faces.registerRocky3D) {
  window.Faces.registerRocky3D(factory);
} else {
  console.warn('rocky3d: faces.js not loaded');
}
