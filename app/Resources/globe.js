// The Zeus globe: a sphere of points that turns slowly, with pointed protrusions that push out once
// and settle back, a ring of light that travels from the centre outward, and a faint inner core.
// It runs on the GPU: the vertex shader moves every point, so a frame costs a few uniform updates.
//
// The Zeus app (theo-henry/zeus-install, app/Resources/globe.js) shows the same globe on its loading
// screen and hands over to this one, so keep the two files the same. The one difference: the app loads
// this file as a plain script, so here createZeusGlobe has no `export`. The turn of the globe comes from
// the wall clock, so that two globes on one screen show the same side at the same moment.

const VERTEX = `
attribute vec4 a;      // xyz on the unit sphere, w = per-point value 0..1
attribute float e;     // 1 = moved point or ray tip, 0 = ray base on the surface
uniform float t, en, now, px, mini, calm;
uniform mediump float mode;   // 0 = surface points, 1 = rays to the peaks, 3 = inner core
uniform vec2 sc; uniform vec4 rot;
uniform vec4 em[10];   // Protrusions: xyz = direction of the peak, w = start time in seconds
uniform float es[10], ed[10];   // their height and duration
varying float va, vk;
// t runs from 0 to 62.5 and then starts again. Every speed of t is a whole number of turns in that
// time (B is one turn), so the wave, the core and the ring of light do not jump when t starts again.
const float B = 6.2831853/62.5;
float wave(vec3 p, float t) {
  return (sin(p.x*1.7+t*B*9.) + sin(p.y*2.1-t*B*11.) + sin(p.z*1.9+t*B*7.) + sin((p.x+p.y)*2.6+t*B*13.) + sin((p.y-p.z)*3.0-t*B*10.)) / 5.;
}
void main() {
  vec3 p = a.xyz;
  vec3 v = vec3(p.x*rot.x + p.z*rot.y, p.y, p.z*rot.x - p.x*rot.y);
  v = vec3(v.x, v.y*rot.z - v.z*rot.w, v.z*rot.z + v.y*rot.w);
  float k = 0., rad = 1.;
  if (mode < 1.5) {
    float spike = 0.;
    for (int i = 0; i < 10; i++) {
      float u = (now - em[i].w)/ed[i];
      if (u > 0. && u < 1.) {
        float env = sin(3.14159*pow(u, .8)); env *= env;          // Rises and falls smoothly.
        vec3 d = em[i].xyz;
        float ang = acos(clamp(dot(p, d), -1., 1.));               // Angle from the peak.
        float width = .34*(1. + .18*wave(p*5. + d*7., 0.));        // Uneven foot, like a mountain.
        float h = max(0., 1. - ang/width);                         // A cone: straight slopes up to the peak.
        float ez = (d.z*rot.x - d.x*rot.y)*rot.z + d.y*rot.w;      // Peaks that turn toward the viewer stay low.
        spike += mix(h, h*h*(3. - 2.*h), .45) * env * es[i] * .9 * mix(.12, 1., (1. - ez*ez)*(1. - ez*ez));
      }
    }
    spike *= calm;   // 0 while the globe holds still for a hand-over.
    rad = 1. + wave(p, t)*.006 + spike*e;
    k = clamp(spike*2.6, 0., 1.);
  } else { rad = .52 + .05*sin(t*B*13. + a.w*6.283); }
  vec3 q = v*rad;
  float s = 3.4/(3.4 - q.z), depth = clamp((q.z + 1.4)/2.8, 0., 1.);
  gl_Position = vec4(q.x*s*sc.x, q.y*s*sc.y, 0., 1.);
  // The ring of light: it starts in the centre and travels outward through the core and the surface.
  float w = fract(t*.16)*2.6;
  float scan = smoothstep(.2, 0., abs(length(q.xy) - w)) * (1. - w/2.6);
  gl_PointSize = 1.;
  if (mode < .5) {
    gl_PointSize = (1.9 + depth*3. + k*3.)*px*s*(1. + mini*2.4);
    va = (.3 + depth*.7)*(.8 + k*.7 + scan*.9)*(1. + mini*.5);
    k = max(k, scan*.6);
  } else if (mode < 1.5) { va = min(.6, k*.75)*(.25 + depth*.75)*(.2 + .8*e);
  } else { gl_PointSize = (1.4 + depth*1.6)*px*s; va = (.12 + depth*.3)*(.7 + en*.6)*(1. + scan*2.5); k = .55 + scan*.4; }
  vk = k;
}`;

const FRAGMENT = `
precision mediump float; uniform float mode; varying float va, vk;
void main() {
  float al = va;
  if (mode < .5 || mode > 1.5) al *= smoothstep(.5, .06, length(gl_PointCoord - .5));
  vec3 c = mix(mix(vec3(.13,.34,1.), vec3(.3,.72,1.), smoothstep(0., .5, vk)), vec3(.92,.97,1.), smoothstep(.5, 1., vk));
  gl_FragColor = vec4(c*al, al);
}`;

const SLOTS = 10;
// The radius of the globe as a part of the smaller side of its canvas. The rest is room for the peaks.
const RADIUS = 0.27;

/** Points spread evenly on a sphere (Fibonacci spiral), and the same points as base and tip of a ray. */
function sphere(count) {
  const points = new Float32Array(count * 4);
  const rays = new Float32Array(count * 10);
  for (let i = 0; i < count; i += 1) {
    const y = 1 - (2 * (i + 0.5)) / count;
    const r = Math.sqrt(1 - y * y);
    const angle = i * 2.399963229728653;
    const x = Math.cos(angle) * r;
    const z = Math.sin(angle) * r;
    const j = (Math.sin(i * 12.9898) * 43758.5453) % 1; // The same for every globe, so two globes look the same.
    points.set([x, y, z, Math.abs(j)], i * 4);
    rays.set([x, y, z, Math.abs(j), 0, x, y, z, Math.abs(j), 1], i * 10);
  }
  return { count, points, rays };
}

/**
 * Creates the globe on a new canvas. Returns null when WebGL is not available.
 * Put `canvas` in the page and call `start()`. The globe draws only while its canvas is visible.
 * `setEnergy(0..1)`: how often and how far the protrusions push out (idle about 0.12, working 1).
 * `setMini(true)`: the small form for a 20 to 30 px globe: fewer and larger points, no core, no rays.
 * `setCalm(true)`: no protrusions, for a hand-over between two globes.
 */
function createZeusGlobe() {
  const canvas = document.createElement("canvas");
  canvas.className = "zeus-globe";
  canvas.setAttribute("aria-hidden", "true");
  const gl = canvas.getContext("webgl", { alpha: true, premultipliedAlpha: true, antialias: true });
  if (!gl) return null;

  const compile = (type, source) => {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    return gl.getShaderParameter(shader, gl.COMPILE_STATUS) ? shader : null;
  };
  const vertex = compile(gl.VERTEX_SHADER, VERTEX);
  const fragment = compile(gl.FRAGMENT_SHADER, FRAGMENT);
  const program = gl.createProgram();
  if (!vertex || !fragment) return null;
  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null;
  gl.useProgram(program);

  const U = {};
  for (const name of ["t", "en", "now", "px", "mini", "calm", "mode", "sc", "rot", "em", "es", "ed"])
    U[name] = gl.getUniformLocation(program, name);
  const A = gl.getAttribLocation(program, "a");
  const E = gl.getAttribLocation(program, "e");
  const upload = (data) => {
    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
    return buffer;
  };
  const shapes = [sphere(3600), sphere(420)].map((shape) => ({
    ...shape,
    pointBuffer: upload(shape.points),
    rayBuffer: upload(shape.rays),
  }));
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.ONE, gl.ONE);
  gl.clearColor(0, 0, 0, 0);

  const still = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
  const em = new Float32Array(SLOTS * 4).fill(-99);
  const es = new Float32Array(SLOTS);
  const ed = new Float32Array(SLOTS).fill(1);
  let mini = false;
  let energy = 0.12;
  let target = 0.12;
  let calm = false;
  let calmNow = 1; // 1 = protrusions at full height, 0 = none
  let slot = 0;
  let ringBefore = 0;
  let last = 0;
  let request = 0;
  let skip = false;
  let width = 0;
  let height = 0;

  // The turn of the globe and the time of its ring of light at this moment, from the wall clock,
  // so that two globes on one screen are the same.
  const turn = () => {
    const seconds = still ? 0 : Date.now() / 1000;
    return {
      spin: (seconds * 0.2) % 6.283185,
      tilt: 0.35 + Math.sin(seconds * 0.21) * 0.12,
      clock: (seconds * 0.7) % 62.5, // Kept small: the shader counts with less precision. See B in the shader.
    };
  };

  // Starts one protrusion. Its peak is one of the globe's own points, near the outline as seen now.
  function protrude(seconds, strength, view) {
    const { points, count } = shapes[mini ? 1 : 0];
    const cx = Math.cos(view.tilt);
    const sx = Math.sin(view.tilt);
    const c = Math.cos(view.spin);
    const s = Math.sin(view.spin);
    let i = 0;
    for (let tries = 0; tries < 40; tries += 1) {
      i = ((Math.random() * count) | 0) * 4;
      const towardViewer = (points[i + 2] * c - points[i] * s) * cx + points[i + 1] * sx;
      if (Math.abs(towardViewer) < 0.38) break;
    }
    em.set([points[i], points[i + 1], points[i + 2], seconds], slot * 4);
    es[slot] = strength * (mini ? 1.5 : 1);
    ed[slot] = 0.9 + strength * 1.6 + Math.random() * 0.4; // Longer ones take longer.
    slot = (slot + 1) % SLOTS;
  }

  function frame(ms) {
    request = requestAnimationFrame(frame);
    const w = canvas.clientWidth;
    const h = canvas.clientHeight;
    if (!canvas.isConnected || w === 0 || h === 0) {
      last = ms;
      return;
    }
    skip = mini && !skip; // The small globe draws every second frame.
    if (skip) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    if (width !== Math.round(w * dpr) || height !== Math.round(h * dpr)) {
      width = canvas.width = Math.round(w * dpr);
      height = canvas.height = Math.round(h * dpr);
      gl.viewport(0, 0, width, height);
    }
    const side = Math.min(width, height);
    const dt = Math.min(0.05, (ms - last) / 1000);
    const seconds = ms / 1000;
    last = ms;
    const view = turn();
    energy += (target - energy) * 0.04;
    calmNow += ((calm ? 0 : 1) - calmNow) * 0.14;
    const clock = view.clock;
    if (!still && !calm) {
      const size = () => (0.16 + Math.random() ** 1.6 * 0.5) * (0.75 + energy * 0.55); // Mostly short, sometimes long.
      if (Math.random() < dt * (0.55 + energy * 3)) protrude(seconds, size(), view);
      // The ring of light reaches the edge of the globe and pushes some out.
      const ring = ((clock * 0.16) % 1) * 2.6;
      if (ringBefore < 0.9 && ring >= 0.9)
        for (let i = 0; i < 2 + Math.round(energy * 2); i += 1) protrude(seconds + i * 0.06, size() * 1.2, view);
      ringBefore = ring;
    }

    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.uniform2f(U.sc, (2 * RADIUS * side) / width, (2 * RADIUS * side) / height);
    gl.uniform1f(U.px, (RADIUS * side) / 150);
    gl.uniform1f(U.mini, mini ? 1 : 0);
    gl.uniform1f(U.calm, calmNow);
    gl.uniform4fv(U.em, em);
    gl.uniform1fv(U.es, es);
    gl.uniform1fv(U.ed, ed);
    gl.uniform1f(U.now, seconds);
    gl.uniform1f(U.t, clock);
    gl.uniform1f(U.en, energy);
    const rotate = (spin, tilt) => gl.uniform4f(U.rot, Math.cos(spin), Math.sin(spin), Math.cos(tilt), Math.sin(tilt));
    const shape = shapes[mini ? 1 : 0];
    gl.enableVertexAttribArray(A);

    if (!mini) {
      rotate(-view.spin * 1.7, view.tilt + 0.5); // The inner core turns the other way.
      gl.bindBuffer(gl.ARRAY_BUFFER, shape.pointBuffer);
      gl.vertexAttribPointer(A, 4, gl.FLOAT, false, 16, 0);
      gl.disableVertexAttribArray(E);
      gl.vertexAttrib1f(E, 1);
      gl.uniform1f(U.mode, 3);
      gl.drawArrays(gl.POINTS, 0, shape.count / 2);

      rotate(view.spin, view.tilt); // Rays from the surface to the peaks.
      gl.bindBuffer(gl.ARRAY_BUFFER, shape.rayBuffer);
      gl.vertexAttribPointer(A, 4, gl.FLOAT, false, 20, 0);
      gl.enableVertexAttribArray(E);
      gl.vertexAttribPointer(E, 1, gl.FLOAT, false, 20, 16);
      gl.uniform1f(U.mode, 1);
      gl.drawArrays(gl.LINES, 0, shape.count * 2);
    }

    rotate(view.spin, view.tilt); // The surface points.
    gl.bindBuffer(gl.ARRAY_BUFFER, shape.pointBuffer);
    gl.vertexAttribPointer(A, 4, gl.FLOAT, false, 16, 0);
    gl.disableVertexAttribArray(E);
    gl.vertexAttrib1f(E, 1);
    gl.uniform1f(U.mode, 0);
    gl.drawArrays(gl.POINTS, 0, shape.count);
  }

  return {
    canvas,
    start() {
      if (!request) request = requestAnimationFrame(frame);
    },
    setEnergy(value) {
      target = Math.max(0, Math.min(1, value));
    },
    setMini(value) {
      if (mini === Boolean(value)) return;
      mini = Boolean(value);
      em.fill(-99); // The peaks of the other form do not fit this one.
    },
    /** Holds the globe still: the protrusions go back and no new ones start. For the hand-over from the app. */
    setCalm(value) {
      calm = Boolean(value);
    },
  };
}
