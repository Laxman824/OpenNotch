// The Dreamer on the Mac desktop — Ledge's body.
//
// Ported from the portfolio component (build_portfolio/.../dreamer/Dreamer.js,
// see its dreamer_readme.md for the design history). The behaviour state
// machine, momentum flight, loops, dash, roll-outs, flare landings, trails and
// poses are kept as tuned there; what changed:
//
//   * No React, no DOM page. The world is the overlay window: world units are
//     screen points, y up from the bottom edge (the reference's convention).
//   * Perches are rectangles pushed in from Swift — the top edges of your app
//     windows — instead of headings/cards. He rides them when a window moves.
//   * The floor is the top of the Dock (GROUND comes from Swift) and he never
//     flies into the menu bar (CEIL).
//   * `attend(point)`: hover beside a point (the notch) using the same
//     critically-damped hover as the reference's follow-cursor. Used when
//     Ledge is working, speaking, or waiting on an approval.
//   * Mochi/scoop is gone (no cat on the desktop).
//
// The simulation (`createSim`) has no renderer, so the same code runs headless
// in Node for statistics (`test/sim.mjs`) and in WKWebView with WebGL.
import * as THREE from "./three.module.js";
import { RoomEnvironment } from "./RoomEnvironment.js";
import {
  PALETTE,
  applyPose,
  buildRig,
  flapArms,
  flarePose,
  dashArms,
  flyBody,
  groundPose,
  mixInto,
  wavePose,
  dancePose,
  celebratePose,
  pointPose,
  sleepPose,
  danglePose,
} from "./DreamerRig.js";

export const PX = 58; // px per metre -> ~105 px tall
const G = 1100;
const WALK = 52;
const RUN = 170;
const CRUISE = 150;
const TRAIL_N = 44;
const MIN_V = 70;
const MAX_V = 360;
const MIN_TURN_R = 85;
const LOOP_R = 80;
const DIVE_G = 240;
const ROLL_VIEW = 0.55;
const TAU = Math.PI * 2;
const HEIGHT = 105; // his height on screen, for head-room checks

const wrap = (a) => Math.atan2(Math.sin(a), Math.cos(a));
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const rand = (lo, hi) => lo + Math.random() * (hi - lo);
const ease = (cur, target, rate, dt) => cur + (target - cur) * (1 - Math.exp(-rate * dt));

const _X = new THREE.Vector3();
const _Y = new THREE.Vector3();
const _Z = new THREE.Vector3();
const _M = new THREE.Matrix4();
const flightQuat = (th, roll, out) => {
  const c = Math.cos(th);
  const sn = Math.sin(th);
  _Y.set(c, sn, 0);
  _Z.set(sn * Math.cos(roll), -c * Math.cos(roll), Math.sin(roll)).normalize();
  _X.crossVectors(_Y, _Z);
  _M.makeBasis(_X, _Y, _Z);
  return out.setFromRotationMatrix(_M);
};

/**
 * The whole character minus the WebGL renderer.
 * @param {object} o
 * @param {number} o.vw  world width (points)
 * @param {number} o.vh  world height (points)
 * @param {"calm"|"lively"} [o.pace]
 * @param {(msg: object) => void} [o.post]  events out (to Swift)
 * @param {object} [o.saved]  {fx, fy, air, th, v} to resume from
 */
export function createSim({
  vw, vh, pace = "calm", post = () => {}, saved = null, light = true,
  // Desktop Ledge (owner's choice): walk only — no flying — bigger and cute.
  walkOnly = false, px = PX, cute = false, avatar = "ledge",
}) {
  const calm = pace === "calm";
  const WALK_V = walkOnly ? 0.9 * px : WALK; // stride-matched for his size
  const HANG = 1.55 * px; // hood (where you hold him) above his feet
  let GROUND = 14; // feet line above the bottom edge (top of the Dock)
  let CEIL = 30; // keep clear of the menu bar at the top

  const scene = new THREE.Scene();
  // Cute/premium mode is lit like a studio portrait: a soft fill from the
  // environment (set by the page), a warm key that casts soft shadows, a cool
  // rim for silhouette, a gentle front fill. The lights follow him (aimLights)
  // because his world is a whole screen and a directional shadow camera has
  // to frame him. The original keeps its flat three-light setup.
  const hemi = new THREE.HemisphereLight("#ffffff", "#8a7f9a", cute ? 0.2 : 0.95);
  scene.add(hemi);
  const key = new THREE.DirectionalLight("#fff1e0", cute ? 1.2 : 0.9);
  key.position.set(-0.6, 1, 1.2);
  scene.add(key);
  scene.add(key.target);
  const rim = new THREE.DirectionalLight(cute ? "#b9c6ff" : "#c7d2fe", cute ? 1.0 : 0.45);
  rim.position.set(1, 0.4, -1);
  scene.add(rim);
  scene.add(rim.target);
  const fill = new THREE.DirectionalLight("#ffe6f2", cute ? 0.35 : 0);
  scene.add(fill);
  scene.add(fill.target);
  const aimLights = (cx, cy, k = 1) => {
    // Offsets in points, scaled with his size; directions are what matter.
    const d = 6 * px * k;
    key.position.set(cx - 0.45 * d, cy + 0.85 * d, 0.9 * d);
    key.target.position.set(cx, cy, 0);
    rim.position.set(cx + 0.9 * d, cy + 0.35 * d, -0.8 * d);
    rim.target.position.set(cx, cy, 0);
    fill.position.set(cx + 0.6 * d, cy - 0.1 * d, 1.0 * d);
    fill.target.position.set(cx, cy, 0);
    key.shadow.camera.left = -2.4 * px * k;
    key.shadow.camera.right = 2.4 * px * k;
    key.shadow.camera.top = 2.4 * px * k;
    key.shadow.camera.bottom = -2.4 * px * k;
    key.shadow.camera.near = 1;
    key.shadow.camera.far = 20 * px * k;
    key.shadow.camera.updateProjectionMatrix();
  };

  const pal = light ? PALETTE.light : PALETTE.dark;
  const rig = buildRig(pal, { cute, style: avatar });
  rig.root.scale.setScalar(px);
  rig.root.rotation.x = 0.32;
  scene.add(rig.root);

  const shadow = new THREE.Mesh(
    new THREE.CircleGeometry(1, 32),
    new THREE.MeshBasicMaterial({ color: pal.shadow, transparent: true, opacity: 0.16, depthWrite: false })
  );
  shadow.position.z = -300;
  scene.add(shadow);

  const makeTrail = () => {
    const geo = new THREE.BufferGeometry();
    const pos = new Float32Array(TRAIL_N * 3);
    const col = new Float32Array(TRAIL_N * 4);
    const c = new THREE.Color(pal.trail).convertSRGBToLinear();
    for (let i = 0; i < TRAIL_N; i += 1) {
      col[i * 4] = c.r;
      col[i * 4 + 1] = c.g;
      col[i * 4 + 2] = c.b;
    }
    geo.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    geo.setAttribute("color", new THREE.BufferAttribute(col, 4));
    const line = new THREE.Line(
      geo,
      new THREE.LineBasicMaterial({ vertexColors: true, transparent: true, depthWrite: false })
    );
    line.frustumCulled = false;
    scene.add(line);
    return { line, pos, col, primed: false };
  };
  const trails = [makeTrail(), makeTrail()];
  const handPos = new THREE.Vector3();
  const qUp = new THREE.Quaternion();
  const qFly = new THREE.Quaternion();
  const _E = new THREE.Euler();

  // ── The world as Swift describes it ───────────────────────────────────────
  // perches: id -> {x1, x2, top} in overlay points, top measured from the TOP.
  let perches = new Map();

  const ctl = { autopilot: true, follow: false, cmd: null, intent: null, attend: null, mouse: null };

  const s = {
    mode: "idle",
    timer: calm ? rand(3, 6) : 1.5,
    t: 0,
    x: calm ? rand(vw * 0.15, vw * 0.6) : vw * 0.25,
    y: GROUND,
    vx: 0,
    vy: 0,
    dir: 1,
    yaw: 0.9,
    phase: 0,
    psi: 0,
    flapA: 0,
    flapF: 1,
    wFly: 0,
    wArms: 0,
    wFlare: 0,
    wTrail: 0,
    dip: 0,
    look: 0,
    lookTarget: 0,
    lookTimer: 2,
    blinkIn: 2.5,
    tt: 0,
    flightT: 0,
    flightDur: 16,
    wp: null,
    wpT: 0,
    landX: 0,
    th: 0,
    v: 0,
    om: 0,
    belly: 1,
    roll: ROLL_VIEW,
    man: null,
    cruise: CRUISE,
    flaring: false,
    wHover: 0,
    wDash: 0,
    flapNeed: 0,
    perch: null, // {id, reason}
    goal: null, // the perch he's flying to
    jumped: false,
    floorAhead: false,
    attending: false,
    lookUp: 0, // 0..1 head tilted up (at the notch)
    // Desktop interactions.
    hover: false, // the pointer is on him
    waveT: 0, // seconds since the hover began (he waves for the first ~2.4s)
    wWave: 0,
    wDangle: 0,
    held: null, // {x, y} feet target while you drag him (world coords)
    // Drag physics: he hangs by the hood (HANG above his feet) and swings like
    // a pendulum; a release throws him with your pointer's momentum.
    swing: 0, // pendulum angle (rad, + = feet to the right)
    swingV: 0,
    sq: 0, // squash (+) / stretch (−) on landing
    sqV: 0,
    pvx: 0, // smoothed pointer velocity while held (pt/s)
    pvy: 0,
    bounces: 0,
    talk: 0, // target mouth opening from Ledge's voice level (0..1)
    music: false, // something is playing: he dances when he's standing about
    bpm: 118,
    beat: 0, // beat phase, radians
    wDance: 0,
    danceW: [1, 0, 0], // blend of bob / pump / sway
    danceMove: 0,
    react: null, // "celebrate" | "point" | null — Swift drives it from Ledge's status
    reactK: 0,
    wCeleb: 0,
    wPoint: 0,
    sleepy: false, // late at night with nothing going on: he dozes
    wakeUntil: 0,
    wSleep: 0,
    talkV: 0,
  };

  // ── Surfaces ─────────────────────────────────────────────────────────────
  const perchRect = (id) => perches.get(id) || null;
  const perchFits = (r) =>
    !!r &&
    r.top >= CEIL + HEIGHT + 15 && // room for his head under the menu bar
    r.top <= vh - GROUND - 40 && // clearly above the floor
    r.x2 - r.x1 >= 90;

  const surface = () => {
    if (!s.perch) return { y: GROUND, x1: 50, x2: vw - 50 };
    const r = perchRect(s.perch.id);
    if (!perchFits(r)) return null;
    return { y: vh - r.top, x1: r.x1 + 22, x2: r.x2 - 22 };
  };

  const pickRestingPerch = () => {
    const ok = [...perches.entries()].filter(([, r]) => perchFits(r));
    if (!ok.length) return null;
    // Prefer ones near him — a short hop, not a cross-screen commute.
    ok.sort((a, b) => Math.abs((a[1].x1 + a[1].x2) / 2 - s.x) - Math.abs((b[1].x1 + b[1].x2) / 2 - s.x));
    const pick = ok[Math.floor(Math.random() * Math.min(3, ok.length))];
    return { id: pick[0], reason: "rest" };
  };

  // ── Resume where he was ──────────────────────────────────────────────────
  if (saved && typeof saved.fx === "number") {
    s.x = clamp(saved.fx * vw, 60, vw - 60);
    if (saved.air && !walkOnly) {
      s.y = clamp(saved.fy * vh, GROUND + 90, vh - CEIL - 90);
      s.th = saved.th || 0;
      s.v = clamp(saved.v || CRUISE, MIN_V, MAX_V);
      s.belly = Math.cos(s.th) >= 0 ? 1 : -1;
      s.roll = s.belly > 0 ? ROLL_VIEW : Math.PI - ROLL_VIEW;
      s.dir = s.belly;
      s.wFly = 1;
      s.wArms = 1;
      s.mode = "fly";
      s.flightDur = rand(5, 10);
    } else {
      s.timer = rand(2, 5);
    }
  }
  const snapshot = () => ({
    at: Date.now(),
    fx: s.x / vw,
    fy: s.y / vh,
    air: !(s.mode === "idle" || s.mode === "walk") || !!s.perch,
    th: s.th,
    v: s.v,
  });

  const setMode = (m, timer = 0) => {
    s.mode = m;
    s.timer = timer;
    s.tt = 0;
    post({ type: "mode", mode: m });
  };

  const top = () => vh - CEIL - 90; // highest comfortable flight line

  const pickWaypoint = () => {
    const hi = top();
    const lo = Math.min(hi - 40, GROUND + vh * 0.28);
    let best = null;
    for (let i = 0; i < 6; i += 1) {
      const c = { x: rand(90, vw - 90), y: rand(lo, hi) };
      const d = Math.hypot(c.x - s.x, c.y - s.y);
      const ahead = Math.cos(Math.atan2(c.y - s.y, c.x - s.x) - s.th);
      const score = -Math.abs(d - 480) + 220 * ahead;
      if (!best || score > best.score) best = { ...c, d, score };
    }
    s.wp = best;
    s.wpT = 0;
    s.cruise = best.d > 520 && Math.random() < (calm ? 0.3 : 0.45) ? 330 : CRUISE;
    const room =
      s.y > GROUND + 140 &&
      s.y + 2 * LOOP_R + 90 < vh - CEIL &&
      s.x > 140 &&
      s.x < vw - 140 &&
      Math.abs(Math.cos(s.th)) > 0.75;
    if (!s.man && room && Math.random() < (calm ? 0.2 : 0.3)) s.man = { sign: s.belly, turned: 0 };
  };

  // Momentum flight (unchanged from the reference; the ceiling is the menu bar).
  const glide = (tx, ty, dt, cruise, floor, landing = false) => {
    const d = Math.hypot(tx - s.x, ty - s.y) || 1;
    let want = Math.atan2(ty - s.y, tx - s.x);
    want += 0.22 * Math.sin(s.t * 0.6) * clamp(d / 300, 0, 1);
    const la = 0.9 * s.v + 60;
    const lx = s.x + Math.cos(s.th) * la;
    const ly = s.y + Math.sin(s.th) * la;
    s.floorAhead = ly < floor;
    const urgent = lx < 60 || lx > vw - 60 || ly > vh - CEIL - 60 || (s.floorAhead && !landing);
    if (urgent) want = Math.atan2(vh * 0.55 - s.y, vw / 2 - s.x);
    let diff = wrap(want - s.th);
    if (Math.abs(diff) > 2.3 && !urgent) {
      const over = !landing && s.y < vh - CEIL - 250 ? 1 : -1;
      diff = over * s.belly * Math.abs(diff);
    }
    const omMax = Math.min(s.v / MIN_TURN_R, 2.3);
    let omT = clamp(diff * (urgent ? 3 : 1.7), -omMax, omMax);
    if (s.man) {
      omT = (s.man.sign * s.v) / LOOP_R;
      s.man.turned += Math.abs(s.om) * dt;
      if (s.man.turned > TAU - 0.2) s.man = null;
    }
    s.om = ease(s.om, omT, 3.2, dt);
    s.th = wrap(s.th + s.om * dt);
    const climb = Math.sin(s.th);
    const need = clamp(0.2 + 1.1 * Math.max(0, climb) + (170 - s.v) / 90, 0, 1) * (1 - s.wDash);
    const pulse = 1 + 0.9 * Math.max(0, -Math.cos(s.psi));
    s.v += (-DIVE_G * climb + 0.8 * (cruise - s.v) + 150 * need * pulse) * dt;
    s.v = clamp(s.v, MIN_V, MAX_V);
    s.vx = Math.cos(s.th) * s.v;
    s.vy = Math.sin(s.th) * s.v;
    return need;
  };

  const hoverTo = (tx, ty, dt) => {
    const k = 7;
    const c = 2 * Math.sqrt(k) * 0.95;
    s.vx += ((tx - s.x) * k - s.vx * c) * dt;
    s.vy += ((ty - s.y) * k - s.vy * c) * dt;
    s.v = Math.max(MIN_V, Math.hypot(s.vx, s.vy));
    if (Math.hypot(s.vx, s.vy) > 50) s.th = Math.atan2(s.vy, s.vx);
    s.om = ease(s.om, 0, 4, dt);
  };

  const startLaunch = () => {
    s.jumped = false;
    if (s.x < 140) s.dir = 1;
    else if (s.x > vw - 140) s.dir = -1;
    setMode("launch");
  };
  const startTakeoff = () => {
    if (s.perch) return startLaunch();
    s.dir = s.x < vw / 2 ? 1 : -1;
    setMode("takeoff");
    return undefined;
  };

  const startLanding = () => {
    if (!s.goal && ctl.autopilot && Math.random() < 0.5) s.goal = pickRestingPerch();
    const r = s.goal && perchRect(s.goal.id);
    if (s.goal && perchFits(r)) {
      s.landX = r.x2 - r.x1 < 70 ? (r.x1 + r.x2) / 2 : clamp(s.x, r.x1 + 30, r.x2 - 30);
    } else {
      s.goal = null;
      const ahead = Math.sign(Math.cos(s.th) || s.dir);
      let lx = s.x + ahead * rand(220, 380);
      if (lx < vw * 0.12 || lx > vw * 0.88) lx = s.x - ahead * rand(220, 380);
      s.landX = clamp(lx, 90, vw - 90);
    }
    s.man = null;
    s.flaring = false;
    setMode("land");
  };

  const enterFlight = () => {
    s.th = Math.atan2(s.vy, s.vx);
    s.v = Math.max(140, Math.hypot(s.vx, s.vy));
    s.om = 0;
    s.flightT = 0;
    s.flightDur = calm ? rand(10, 16) : rand(14, 22);
    if (s.goal && !ctl.attend) return startLanding();
    pickWaypoint();
    setMode("fly");
    return undefined;
  };

  const wake = () => {
    if (s.sleepy) {
      s.sleepy = false;
      s.wakeUntil = s.t + 120;
    }
  };

  const nextOnGround = () => {
    if (walkOnly) {
      // A stroll, a pause, a stroll: never takes off.
      if (s.sleepy || s.react) {
        setMode("idle", rand(20, 40)); // dozing, or busy reacting: stay put
      } else if (s.mode === "idle" && s.music && Math.random() < 0.8) {
        setMode("idle", rand(12, 24)); // the song's on: keep dancing
      } else if (s.mode === "idle") {
        s.dir = s.x < vw * 0.2 ? 1 : s.x > vw * 0.8 ? -1 : Math.random() < 0.5 ? -1 : 1;
        setMode("walk", s.music ? rand(2, 3.5) : rand(3, 7));
      } else setMode("idle", s.music ? rand(12, 24) : calm ? rand(4, 10) : rand(2, 4));
      return;
    }
    if (s.perch) {
      const surf = surface();
      const roomy = surf && surf.x2 - surf.x1 > 120;
      const r = Math.random();
      if (roomy && s.mode === "idle" && r < 0.35) {
        s.dir = Math.random() < 0.5 ? -1 : 1;
        setMode("walk", rand(1.5, 3));
      } else if (r < (calm ? 0.5 : 0.75)) startLaunch();
      else setMode("idle", calm ? rand(8, 16) : rand(2, 4));
      return;
    }
    if (s.mode === "idle") {
      s.dir = s.x < 120 ? 1 : s.x > vw - 120 ? -1 : Math.random() < 0.5 ? -1 : 1;
      setMode("walk", rand(2.5, 4.5));
    } else if (Math.random() < (calm ? 0.35 : 0.65)) startTakeoff();
    else setMode("idle", calm ? rand(8, 16) : rand(1.8, 3.5));
  };

  // ── One simulation step ──────────────────────────────────────────────────
  const step = (dt) => {
    s.t += dt;
    s.tt += dt;
    const alt = s.y - GROUND;
    const grounded = s.mode === "idle" || s.mode === "walk";

    const cmd = walkOnly && (ctl.cmd === "takeoff" || ctl.cmd === "land") ? null : ctl.cmd;
    ctl.cmd = null;
    if (cmd === "takeoff" && grounded) startTakeoff();
    else if (cmd === "land" && s.mode === "launch") s.goal = null;
    else if (cmd === "land" && (s.mode === "fly" || s.mode === "takeoff")) startLanding();
    else if (cmd === "walk" && grounded) setMode("walk", rand(3, 5));

    // Attend (Ledge needs you): get airborne and go to the notch — or, when
    // he only walks, stroll over and stand under it looking up.
    let brisk = false;
    if (walkOnly && ctl.attend && grounded) {
      const spot = clamp(ctl.attend.x + (s.x < ctl.attend.x ? -1 : 1) * ctl.attend.side * 0.35, 60, vw - 60);
      const dx = spot - s.x;
      if (Math.abs(dx) > 14) {
        if (s.mode !== "walk") setMode("walk", 1e9);
        s.dir = Math.sign(dx);
        brisk = true;
        s.attending = false;
      } else {
        if (s.mode !== "idle") setMode("idle", 1e9);
        s.attending = true;
      }
    }
    if (!walkOnly && ctl.attend && grounded && s.tt > 0.05) startLaunch();
    if (!walkOnly && ctl.attend && s.mode === "land" && !s.flaring) {
      s.goal = null;
      setMode("fly");
    }

    const intent = walkOnly ? null : ctl.intent;
    ctl.intent = null;
    if (intent && ctl.autopilot && !ctl.follow && !ctl.attend && !(s.perch && s.perch.id === intent.id)) {
      s.goal = intent;
      if (grounded) startLaunch();
      else if (s.mode === "fly" || s.mode === "land") startLanding();
    }

    let wFly = 0;
    let wArms = 0;
    let wFlare = 0;
    let flapA = 0;
    let flapF = 1;
    let climb = 0;
    let wHover = 0;

    if (s.mode === "held") {
      // Dangling from your pointer: the hood follows it closely; the body
      // swings under it, driven by how the pointer accelerates.
      const tx = s.held ? s.held.x : s.x;
      const ty = s.held ? s.held.y : s.y;
      const nx = ease(s.x, tx, 10, dt); // a body has weight: it trails the hand
      const ny = ease(s.y, ty, 10, dt);
      const vx = (nx - s.x) / Math.max(dt, 1e-3);
      const vy = (ny - s.y) / Math.max(dt, 1e-3);
      const ax = (vx - s.vx) / Math.max(dt, 1e-3);
      s.vx = vx;
      s.vy = vy;
      s.pvx = ease(s.pvx, vx, 14, dt);
      s.pvy = ease(s.pvy, vy, 14, dt);
      s.x = nx - s.vx * dt; // integrate below applies vx/vy
      s.y = ny - s.vy * dt;
      s.swingV += (-0.11 * clamp(ax, -12000, 12000) / HANG) * dt;
      // Pulled up fast = a little stretch.
      s.sqV += (-clamp(vy, -1500, 1500) / 30000) * dt * 20;
    } else if (s.mode === "fall") {
      s.vy -= G * dt;
      s.vx *= Math.exp(-0.35 * dt); // light air drag: a throw carries
      const nx = s.x + s.vx * dt;
      // Screen edges and the menu bar: bounce, losing some speed.
      if (nx < 30 || nx > vw - 30) {
        s.vx = -s.vx * 0.35;
        s.swingV += s.vx * 0.0015;
        s.sqV += 0.6;
      }
      const top = vh - CEIL - 2.1 * px;
      if (s.y > top && s.vy > 0) {
        s.vy = -s.vy * 0.25;
        s.sqV += 0.6;
      }
      if (s.y + s.vy * dt <= GROUND) {
        const impact = -s.vy;
        s.y = GROUND;
        s.sqV += clamp(impact / 450, 0.3, 2.2); // squash, scaled by the impact
        if (impact > 750 && s.bounces < 1) {
          // A hard landing hops back up once or twice.
          s.bounces += 1;
          s.vy = impact * 0.18;
          s.vx *= 0.5;
          s.swingV += s.vx * 0.001;
        } else {
          s.vy = 0;
          s.vx = 0;
          s.dip = clamp(0.08 + impact / 7000, 0.08, 0.2); // knees absorb it
          post({ type: "landed" });
          setMode("idle", rand(2, 4));
        }
      }
    } else if (s.mode === "idle" || s.mode === "walk") {
      const surf = surface();
      if (!surf) {
        // His window closed, moved off-screen or got covered: spring off.
        s.perch = null;
        startLaunch();
        s.tt = 0.22;
      } else {
        // Pointer on him: stop, turn to you (a wave plays from the pose mix).
        if (s.hover && !brisk && s.mode === "walk") setMode("idle", 1e9);
        const target = s.mode === "walk" ? s.dir * WALK_V * (brisk ? 1.7 : 1) : 0;
        s.vx = ease(s.vx, target, s.mode === "walk" ? 2.5 : 4, dt);
        if (s.mode === "walk" && !brisk) {
          if (s.x < surf.x1) s.dir = 1;
          if (s.x > surf.x2) s.dir = -1;
        }
        s.timer -= dt;
        if (s.timer <= 0 && ctl.autopilot && !(walkOnly && ctl.attend) && !s.hover) nextOnGround();
        else if (s.timer <= 0 && s.mode === "walk") setMode("idle", 1e9);
      }
    } else if (s.mode === "launch") {
      const tt = s.tt;
      wArms = clamp(tt / 0.25, 0, 1);
      flapA = 0.85;
      flapF = 1.6;
      if (tt < 0.22) {
        s.vx = ease(s.vx, 0, 6, dt);
        s.vy = 0;
        s.dip = Math.max(s.dip, 0.08 * (tt / 0.22));
        const surf = surface();
        if (surf && (s.perch || s.y <= GROUND + 1)) s.y = surf.y;
      } else {
        if (!s.jumped) {
          s.jumped = true;
          s.perch = null;
          s.vy = 270;
          s.vx = s.dir * 110;
        }
        s.vy -= 260 * dt;
      }
      wFly = clamp((tt - 0.22) / 0.5, 0, 1);
      climb = clamp(s.vy / 160, -1, 1);
      if (tt > 0.75) enterFlight();
    } else if (s.mode === "takeoff") {
      const tt = s.tt;
      const runUp = tt < 1.2 ? 0 : clamp((tt - 1.2) / 1.4, 0, 1);
      s.vx = ease(s.vx, s.dir * (WALK + (RUN - WALK) * runUp), 2.2, dt);
      if (alt < 2 && (s.x < 40 || s.x > vw - 40)) s.dir = s.x < 40 ? 1 : -1;
      wArms = clamp((tt - 1.6) / 0.8, 0, 1);
      flapA = 0.3 + 0.55 * clamp((tt - 1.6) / 1.6, 0, 1);
      flapF = 1.0;
      const k = clamp((tt - 2.4) / 3.2, 0, 1.2);
      const down = Math.max(0, -Math.cos(s.psi));
      const lift = G * k * 1.15 * (1 + 0.9 * down) * wArms;
      s.vy += (lift - G) * dt;
      s.vy = Math.min(s.vy, 55 + 45 * k);
      if (alt > 1 && Math.abs(s.x - vw / 2) > vw / 2 - 60) s.vx *= 1 - dt * 2;
      wFly = clamp(alt / 110, 0, 1) * 0.85;
      climb = clamp(s.vy / 160, -1, 1);
      if (alt > 110) enterFlight();
    } else if (s.mode === "fly") {
      s.flightT += dt;
      s.wpT += dt;
      const attend = ctl.attend; // {x, y} world coords (y up)
      const follow = !attend && ctl.follow && ctl.mouse;
      let tx;
      let ty;
      if (attend) {
        // Beside the point, on the side he's on — never on top of it.
        tx = attend.x + (s.x < attend.x ? -attend.side : attend.side);
        ty = clamp(attend.y, GROUND + 90, top());
        s.cruise = CRUISE;
        s.man = null;
      } else if (follow) {
        tx = ctl.mouse.x + (s.x < ctl.mouse.x ? -95 : 95);
        ty = clamp(ctl.mouse.y - 85, GROUND + 90, top());
        s.cruise = CRUISE;
      } else {
        if (!s.wp || s.wpT > 8 || Math.hypot(s.wp.x - s.x, s.wp.y - s.y) < 90) pickWaypoint();
        tx = s.wp.x;
        ty = s.wp.y;
      }
      const target = attend || follow;
      const hovering = target && !s.man && Math.hypot(tx - s.x, ty - s.y) < (s.wHover > 0.5 ? 170 : 120);
      if (hovering) {
        hoverTo(tx, ty, dt);
        s.flapNeed = 0.45;
      } else {
        s.flapNeed = glide(tx, ty, dt, s.cruise, GROUND + 70);
      }
      wHover = hovering ? 1 : 0;
      wFly = 1;
      wArms = 1;
      flapA = hovering ? 0.32 : 0.1 + 0.55 * s.flapNeed;
      flapF = hovering ? 1.1 : 0.45 + 0.85 * s.flapNeed;
      climb = Math.sin(s.th);
      s.attending = !!attend && hovering;
      if (s.flightT > s.flightDur && ctl.autopilot && !ctl.follow && !attend && !s.man) startLanding();
    } else if (s.mode === "land") {
      let tx = s.landX;
      let ty = GROUND;
      if (s.goal) {
        const r = perchRect(s.goal.id);
        if (perchFits(r)) {
          ty = vh - r.top;
          tx = clamp(s.landX, r.x1 + 20, r.x2 - 20);
          if (r.x2 - r.x1 < 60) tx = (r.x1 + r.x2) / 2;
        } else {
          s.goal = null;
        }
      }
      const altT = s.y - ty;
      const ay = Math.min(ty + 80, top());
      const d = Math.hypot(tx - s.x, ay - s.y);
      if (
        !s.flaring &&
        altT > -5 &&
        (d < 110 || altT < 60 || (altT < 170 && Math.abs(tx - s.x) < 200) || (s.floorAhead && altT < 260))
      )
        s.flaring = true;
      if (!s.flaring) {
        s.flapNeed = glide(tx, ay, dt, 125, ty + 20, true);
        flapA = 0.1 + 0.5 * s.flapNeed;
        flapF = 0.45 + 0.8 * s.flapNeed;
      } else {
        const aim = s.goal ? clamp((tx - s.x) * 1.8, -140, 140) : Math.sign(s.vx) * 25;
        s.vx = ease(s.vx, aim, s.goal ? 2.4 : 1.6, dt);
        s.vy = ease(s.vy, altT > 0 ? -105 : 0, 2.4, dt);
        wFlare = 1;
        flapA = 0.6;
        flapF = 1.5;
        if (s.goal && altT < -30) s.goal = null;
      }
      wFly = 1;
      wArms = 1;
      climb = Math.sin(s.th) * (1 - s.wFlare);
      const onSpot = !s.goal || Math.abs(s.x - tx) < 45;
      if (altT <= 1.5 && s.vy <= 0 && onSpot) {
        s.y = ty;
        s.vy = 0;
        s.dip = 0.09;
        s.flaring = false;
        if (s.goal) {
          s.perch = s.goal;
          s.goal = null;
          s.vx = 0;
          post({ type: "perch", id: s.perch.id, reason: s.perch.reason });
          setMode("idle", calm ? rand(8, 16) : rand(2.5, 4));
        } else {
          s.perch = null;
          s.vx = clamp(s.vx, -110, 110);
          s.dir = s.vx >= 0 ? 1 : -1;
          setMode("walk", rand(1.2, 2));
        }
      }
    }

    // Integrate.
    s.x += s.vx * dt;
    s.y += s.vy * dt;
    if (s.y < GROUND) {
      s.y = GROUND;
      if (s.vy < 0) s.vy = 0;
    }
    if (s.mode === "held" || s.mode === "fall") s.x = clamp(s.x, 30, vw - 30);
    if (s.mode === "idle" || s.mode === "walk") {
      s.vy = 0;
      const surf = surface();
      if (surf) {
        s.y = surf.y; // ride the window as it moves
        if (s.perch) s.x = clamp(s.x, surf.x1 - 10, surf.x2 + 10);
      }
    }
    s.x = clamp(s.x, 30, vw - 30);
    s.y = Math.min(s.y, vh - CEIL - 60);

    s.wFly = ease(s.wFly, wFly, 2.4, dt);
    s.wArms = ease(s.wArms, wArms, 3.2, dt);
    s.wFlare = ease(s.wFlare, wFlare, 3, dt);
    s.wHover = ease(s.wHover, wHover, 2.2, dt);
    s.wDash = ease(s.wDash, s.mode === "fly" && !s.man ? clamp((s.v - 235) / 70, 0, 1) : 0, 2.5, dt);
    if (s.mode !== "fly" && !(s.mode === "land" && !s.flaring)) {
      if (Math.hypot(s.vx, s.vy) > 20) s.th = Math.atan2(s.vy, s.vx);
      s.v = Math.hypot(s.vx, s.vy);
    }
    if (!s.man) {
      if (Math.cos(s.th) > 0.35) s.belly = 1;
      else if (Math.cos(s.th) < -0.35) s.belly = -1;
    }
    const bank = clamp(s.om * 0.16, -0.3, 0.3) * s.belly;
    const rollT = (s.belly > 0 ? ROLL_VIEW : Math.PI - ROLL_VIEW) + bank + 0.05 * Math.sin(s.t * 1.3);
    s.roll = ease(s.roll, rollT, 3.2, dt);
    s.flapA = ease(s.flapA, flapA, 2.5, dt);
    s.flapF = ease(s.flapF, flapF, 2.5, dt);
    s.wTrail = ease(s.wTrail, s.mode === "fly" || s.mode === "land" ? 1 : 0, 1.5, dt);
    // Pendulum under the hood: gravity pulls it straight, air damps it; on the
    // ground he rights himself quickly. The squash is a stiff spring.
    const onFeet = s.mode !== "held" && s.mode !== "fall";
    s.swingV += (-(G / HANG) * Math.sin(s.swing) - (onFeet ? 14 : 3.2) * s.swingV) * dt;
    if (onFeet) s.swingV += -s.swing * 60 * dt;
    // A person hung by the hood only swings so far (~25°); beyond it, stiffen.
    s.swing = clamp(s.swing + s.swingV * dt, -0.45, 0.45);
    if (Math.abs(s.swing) === 0.45) s.swingV *= 0.2;
    s.sqV += (-170 * s.sq - 20 * s.sqV) * dt; // near-critically damped: no jelly wobble
    s.sq = clamp(s.sq + s.sqV * dt, -0.05, 0.1);
    s.dip = ease(s.dip, 0, 5, dt);

    const speed = Math.abs(s.vx);
    if (speed > 18) s.dir = s.vx > 0 ? 1 : -1;
    const run = clamp((speed - 80) / 90, 0, 1);
    const amp = clamp(speed / 45, 0, 1);
    s.phase += (dt * 2 * Math.PI * speed) / (px * (1.3 + 0.7 * run));
    s.psi += dt * 2 * Math.PI * s.flapF;

    s.lookTimer -= dt;
    if (s.lookTimer <= 0) {
      s.lookTimer = rand(1.4, 3.2);
      s.lookTarget =
        s.mode === "idle" && Math.random() < 0.35 ? -s.yaw * 0.75 : s.mode === "idle" ? rand(-0.5, 0.5) : 0;
    }
    if (walkOnly && s.attending) s.lookTarget = -s.yaw * 0.75; // face you
    s.look = ease(s.look, s.lookTarget, 3, dt);
    s.lookUp = ease(s.lookUp, walkOnly && s.attending ? 1 : 0, 3, dt);
    s.waveT = s.hover ? s.waveT + dt : 0;
    const facing = s.hover || s.mode === "held" || s.wDance > 0.5 || s.wCeleb > 0.5 || s.wPoint > 0.5;
    if (facing) s.lookTarget = 0;
    const yawTarget = facing ? 0 : s.dir * (s.mode === "idle" ? 0.75 : 1.15 - 0.35 * Math.max(s.wFly, s.wArms));
    s.yaw = ease(s.yaw, yawTarget, 4, dt);

    const P = groundPose({ phase: s.phase, amp, run, t: s.t, lookY: s.look });
    P.neckX -= 0.42 * s.lookUp; // chin up, toward the notch
    s.wWave = ease(s.wWave, s.hover && s.mode === "idle" && s.waveT < 2.4 ? 1 : 0, 6, dt);
    s.wDangle = ease(s.wDangle, s.mode === "held" ? 1 : 0, 8, dt);
    mixInto(P, wavePose({ t: s.t }), s.wWave);
    mixInto(P, danglePose({ t: s.t }), s.wDangle);
    // Dance on the beat while music plays and he's standing about.
    s.beat += dt * 2 * Math.PI * (s.bpm / 60);
    const dancing = s.music && s.mode === "idle" && !s.hover && !s.attending && s.wWave < 0.05
      && !s.sleepy && !s.react;
    s.wDance = ease(s.wDance, dancing ? 1 : 0, 3, dt);
    if (s.wDance > 0.001) {
      const bar = Math.floor(s.beat / (2 * Math.PI) / 8); // new move every 8 beats
      if (bar !== s.danceBar) {
        s.danceBar = bar;
        s.danceMove = (s.danceMove + 1 + (Math.random() < 0.5 ? 1 : 0)) % 3;
      }
      for (let i = 0; i < 3; i += 1) s.danceW[i] = ease(s.danceW[i], i === s.danceMove ? 1 : 0, 3, dt);
      const pumpSide = Math.floor(s.beat / (2 * Math.PI) / 4) % 2 === 0 ? 1 : -1;
      mixInto(P, dancePose({ b: s.beat, w: s.danceW, pumpSide }), s.wDance);
    }
    // Reactions to Ledge: celebrate "Done ✓", point at the notch for an OK, doze at night.
    if (s.react === "celebrate") {
      s.reactK += dt;
      if (s.reactK > 2.6) s.react = null;
    }
    const onGround = s.mode === "idle" || s.mode === "walk";
    s.wCeleb = ease(s.wCeleb, s.react === "celebrate" && onGround ? 1 : 0, 9, dt);
    s.wPoint = ease(s.wPoint, s.react === "point" && s.mode === "idle" && !s.hover ? 1 : 0, 6, dt);
    s.wSleep = ease(s.wSleep, s.sleepy && s.mode === "idle" && !s.hover && !s.react ? 1 : 0, 1.2, dt);
    if (s.wSleep > 0.001) mixInto(P, sleepPose({ t: s.t }), s.wSleep);
    if (s.wPoint > 0.001) mixInto(P, pointPose({ t: s.t }), s.wPoint);
    if (s.wCeleb > 0.001) mixInto(P, celebratePose({ t: s.t, k: s.reactK }), s.wCeleb);
    // Follow-through: legs trail the swing and the torso counters it a little,
    // so the body bends like a body rather than rotating as one stiff piece.
    const lag = clamp(s.swingV, -2, 2) * s.wDangle;
    P.thL = (P.thL || 0) + 0.22 * lag;
    P.thR = (P.thR || 0) + 0.22 * lag;
    P.knL = (P.knL || 0) + 0.12 * Math.abs(lag);
    P.knR = (P.knR || 0) + 0.12 * Math.abs(lag);
    P.lean = (P.lean || 0) - 0.12 * s.swing * s.wDangle;
    const turn = clamp((s.om * s.belly) / 2, -1, 1);
    mixInto(P, flyBody({ t: s.t, climb, turn, speed: s.v, hoverVx: s.vx * s.dir }), s.wFly);
    mixInto(P, flarePose(), s.wFlare);
    const wOrient = s.wFly * (1 - s.wHover) * (1 - s.wFlare);
    const f = Math.sin(s.psi + 0.5 * Math.sin(s.psi));
    const upstroke = Math.max(0, Math.cos(s.psi));
    mixInto(P, flapArms({ f, A: s.flapA, p: wOrient, upstroke }), s.wArms);
    mixInto(P, dashArms(), s.wDash * s.wArms);
    P.hipsY -= s.dip;
    applyPose(rig, P);
    s.talkV = ease(s.talkV, s.talk, 22, dt);
    if (rig.setTalk) rig.setTalk(s.talkV);
    if (rig.tick) rig.tick(dt, s.mode === "walk" || s.wWave > 0.05 || s.wDangle > 0.05 || s.wDance > 0.05 || s.wCeleb > 0.05 ? 1 : 0);

    s.blinkIn -= dt;
    if (s.blinkIn < -0.15) s.blinkIn = Math.random() < 0.15 ? 0.25 : rand(2.2, 5.5);
    rig.setBlink(Math.max(s.blinkIn < 0 ? Math.sin((-s.blinkIn / 0.15) * Math.PI) : 0, s.wSleep));

    _E.set(P.pitch, s.yaw, 0, "YXZ");
    qUp.setFromEuler(_E);
    flightQuat(s.th, s.roll, qFly);
    rig.yaw.rotation.set(0, 0, 0);
    rig.pitch.quaternion.copy(qUp).slerp(qFly, wOrient);
    const bob = Math.sin(s.psi) * 4 * s.flapA * s.wHover;
    // Hanging/tumbling: rotate about the hood point (HANG above the feet),
    // squash about the feet so they stay planted.
    const sw = s.swing;
    rig.root.rotation.z = sw;
    rig.root.position.set(s.x + HANG * Math.sin(sw), s.y + bob + HANG * (1 - Math.cos(sw)), 0);
    rig.root.scale.set(px * (1 + 0.45 * s.sq), px * (1 - s.sq), px * (1 + 0.45 * s.sq));
    aimLights(s.x, s.y + 0.95 * px);

    const floorY = s.perch && (s.mode === "idle" || s.mode === "walk") ? s.y : GROUND;
    const a = clamp((s.y - floorY) / 320, 0, 1);
    shadow.position.set(s.x, floorY + 1, -300);
    shadow.scale.set(26 * (1 - 0.55 * a), 4.5 * (1 - 0.55 * a), 1);
    shadow.material.opacity = 0.16 * (1 - 0.8 * a);
    s.shadow = { x: s.x, y: floorY + 1, rx: 26 * (1 - 0.55 * a), ry: 4.5 * (1 - 0.55 * a), o: 0.16 * (1 - 0.8 * a) };

    rig.root.updateMatrixWorld(true);
    ["L", "R"].forEach((k, i) => {
      const tr = trails[i];
      rig.legs[k].ankle.getWorldPosition(handPos);
      const { pos, col } = tr;
      if (!tr.primed) {
        for (let j = 0; j < TRAIL_N; j += 1) {
          pos[j * 3] = handPos.x;
          pos[j * 3 + 1] = handPos.y;
          pos[j * 3 + 2] = -50;
        }
        tr.primed = true;
      }
      pos.copyWithin(0, 3);
      pos[(TRAIL_N - 1) * 3] = handPos.x;
      pos[(TRAIL_N - 1) * 3 + 1] = handPos.y;
      pos[(TRAIL_N - 1) * 3 + 2] = -50;
      for (let j = 0; j < TRAIL_N; j += 1)
        col[j * 4 + 3] =
          Math.pow(j / (TRAIL_N - 1), 1.8) * 0.42 * s.wTrail * clamp(s.v / 260, 0.25, 1) * (1 - s.wHover * 0.7);
      tr.line.geometry.attributes.position.needsUpdate = true;
      tr.line.geometry.attributes.color.needsUpdate = true;
    });
  };

  // ── Public API (Swift drives these through the bridge) ───────────────────
  return {
    s,
    rig,
    scene,
    shadowMesh: shadow,
    lights: { hemi, key, rim, fill },
    aimLights,
    step,
    snapshot,
    /** World size and the band he may use (floor = top of the Dock). */
    setWorld({ w, h, floor, ceil }) {
      vw = w;
      vh = h;
      if (typeof floor === "number") GROUND = floor;
      if (typeof ceil === "number") CEIL = ceil;
      s.x = clamp(s.x, 40, vw - 40);
      s.y = clamp(s.y, GROUND, vh - CEIL - 60);
    },
    get size() {
      return { vw, vh, GROUND, CEIL };
    },
    /** [{id, x1, x2, top}] in overlay points, top from the top edge. */
    setPerches(list) {
      perches = new Map((list || []).map((p) => [String(p.id), { x1: p.x1, x2: p.x2, top: p.top }]));
    },
    /** Land on this perch (e.g. the window you just switched to). */
    intent(id, reason = "focus") {
      if (perches.has(String(id))) ctl.intent = { id: String(id), reason };
    },
    /** Hover beside a point (overlay points, y from the top), or null to release. */
    attend(p) {
      if (p) {
        ctl.attend = { x: p.x, y: vh - p.y, side: p.side || 120 };
      } else if (ctl.attend) {
        ctl.attend = null;
        s.attending = false;
        if (walkOnly) {
          setMode("idle", rand(2, 4));
          return;
        }
        // Wander a little more, then come down on his own.
        s.flightDur = Math.max(s.flightT + rand(3, 6), 0);
      }
    },
    command(c) {
      ctl.cmd = c;
    },
    /** Mouth opening while Ledge speaks, 0..1 (Swift sends the TTS level). */
    setTalk(v) {
      s.talk = clamp(+v || 0, 0, 1);
    },
    setHover(on) {
      s.hover = !!on && (s.mode === "idle" || s.mode === "walk");
      if (on) wake();
    },
    /** "celebrate" (a couple of seconds), "point" (until cleared) or null. */
    react(kind) {
      const k = kind === "celebrate" || kind === "point" ? kind : null;
      if (k === "celebrate") {
        s.reactK = 0;
        wake();
        if (s.mode === "walk" && !s.attending) setMode("idle", 3);
      }
      if (k === s.react) return;
      if (s.react === "point" && !k && s.mode === "idle") setMode("idle", rand(2, 4));
      s.react = k;
    },
    /** Late at night with nothing going on (Swift decides). Hover wakes him for 2 min. */
    setSleepy(on) {
      if (on && s.t < s.wakeUntil) return;
      s.sleepy = !!on;
      if (s.sleepy && s.mode === "walk") setMode("idle", rand(20, 40));
    },
    /** Music playing (Swift sends it from "now playing"): he dances when idle. */
    setMusic(on, bpm) {
      const was = s.music;
      s.music = !!on;
      if (bpm) s.bpm = clamp(+bpm || 118, 70, 170);
      // Song starts while he's strolling: stop and dance.
      if (s.music && !was && s.mode === "walk" && ctl.autopilot && !s.hover) setMode("idle", rand(12, 24));
    },
    /** Pick him up; x, y = pointer in overlay points (y from the top). */
    grab(x, y) {
      wake();
      s.perch = null;
      s.hover = false;
      s.pvx = 0;
      s.pvy = 0;
      s.sqV -= 0.35; // a slight stretch as he's lifted
      setMode("held", 1e9);
      this.dragTo(x, y);
    },
    dragTo(x, y) {
      // Held by the hood: the pointer is just above his shoulders.
      s.held = { x, y: Math.max(GROUND, vh - y - 1.55 * px) };
    },
    drop() {
      if (s.mode !== "held") return;
      s.held = null;
      // Thrown with the pointer's momentum (smoothed, so a jittery release
      // doesn't fling him); a gentle release just drops.
      s.vx = clamp(s.pvx * 0.7, -750, 750);
      s.vy = clamp(s.pvy * 0.7, -400, 550);
      s.swingV += -s.vx * 0.0008;
      s.bounces = 0;
      setMode("fall");
    },
    setFollow(on) {
      ctl.follow = !!on;
    },
    setMouse(x, y) {
      ctl.mouse = { x, y: vh - y };
    },
    setAutopilot(on) {
      ctl.autopilot = !!on;
    },
    /** Screen box around his body (overlay points, y from the top). */
    hitBox() {
      const hw = 0.55 * px;
      const cy = vh - (s.y + 0.95 * px);
      return { x: s.x - hw, y: cy - 1.2 * px, w: 2 * hw, h: 2.4 * px };
    },
    dispose() {
      rig.dispose();
      shadow.geometry.dispose();
      shadow.material.dispose();
      trails.forEach((t) => {
        t.line.geometry.dispose();
        t.line.material.dispose();
      });
    },
  };
}

// ── Browser mount (WKWebView) ──────────────────────────────────────────────
// Everything below only runs with a real window/WebGL.
export function mount(host) {
  const post = (msg) => {
    try {
      window.webkit.messageHandlers.dreamer.postMessage(msg);
    } catch (e) {
      /* opened in a normal browser for debugging */
    }
  };
  let saved = null;
  try {
    saved = JSON.parse(localStorage.getItem("dreamer:state") || "null");
    if (saved && Date.now() - saved.at > 30 * 60 * 1000) saved = null;
  } catch (e) {
    saved = null;
  }

  let vw = window.innerWidth;
  let vh = window.innerHeight;
  // Performance: the canvas is NOT full-screen. A small square follows him
  // (moved with a GPU transform) and the orthographic camera frames just his
  // neighbourhood. A full-screen WebGL layer cost ~40% CPU in WebKit's
  // compositor for a 105-pt figure; this is ~20x fewer pixels.
  const BOX = 360;
  const renderer = new THREE.WebGLRenderer({ alpha: true, antialias: true, powerPreference: "low-power" });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.setSize(BOX, BOX);
  renderer.setClearColor(0x000000, 0);
  renderer.outputEncoding = THREE.sRGBEncoding;
  // Premium look: filmic tone mapping (rich, not flat, colour) and soft
  // shadows. Cheap here because the canvas is small (see BOX).
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 0.9;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  const cv = renderer.domElement;
  cv.style.position = "absolute";
  cv.style.left = "0";
  cv.style.top = "0";
  cv.style.willChange = "transform";
  host.appendChild(cv);
  // His shadow lives on the floor, which can be far below the box: a CSS ellipse.
  const shade = document.createElement("div");
  shade.style.cssText =
    "position:absolute;left:0;top:0;border-radius:50%;will-change:transform,opacity;" +
    "background:radial-gradient(closest-side, rgba(20,16,40,.9), rgba(20,16,40,0));";
  host.appendChild(shade);
  const camera = new THREE.OrthographicCamera(0, BOX, BOX, 0, 1, 4000);
  camera.position.z = 2000;
  const frameCamera = (s) => {
    // Centre on his body (feet + ~half his height), snapped to whole points
    // so the texture doesn't shimmer as the box moves.
    const cx = Math.round(s.x);
    const cy = Math.round(s.y + 0.95 * SIZE);
    camera.left = cx - BOX / 2;
    camera.right = cx + BOX / 2;
    camera.bottom = cy - BOX / 2;
    camera.top = cy + BOX / 2;
    camera.updateProjectionMatrix();
    cv.style.transform = `translate3d(${cx - BOX / 2}px, ${vh - (cy + BOX / 2)}px, 0)`;
    const sh = s.shadow;
    if (sh) {
      shade.style.width = `${sh.rx * 2}px`;
      shade.style.height = `${sh.ry * 2}px`;
      shade.style.opacity = String(Math.min(1, sh.o * 2.2));
      shade.style.transform = `translate3d(${sh.x - sh.rx}px, ${vh - sh.y - sh.ry}px, 0)`;
    }
  };
  const SIZE = 88; // px per metre on the desktop: ~160 pt tall with the big head
  // Which character walks the desktop: "ledge" (default), "bee" or "cat", chosen in
  // the notch menu and passed as ?avatar= by Swift.
  const want = new URLSearchParams(location.search).get("avatar");
  const avatar = ["bee", "cat"].includes(want) ? want : "ledge";
  const sim = createSim({ vw, vh, pace: "calm", post, saved, walkOnly: true, px: SIZE, cute: true, avatar });
  sim.shadowMesh.visible = false; // drawn by CSS instead (see above)
  // Studio environment: soft, even reflections on every material.
  const pmrem = new THREE.PMREMGenerator(renderer);
  sim.scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
  pmrem.dispose();
  // The room is bright; at full strength it bleaches skin and fabric.
  sim.rig.root.traverse((o) => {
    if (o.isMesh && o.material && "envMapIntensity" in o.material && o.material.envMapIntensity === 1)
      o.material.envMapIntensity = 0.55;
  });
  // Soft self-shadows (head on the hoodie, arms on the body).
  const key = sim.lights.key;
  key.castShadow = true;
  key.shadow.mapSize.set(512, 512);
  key.shadow.bias = -0.0004;
  key.shadow.normalBias = 0.6;
  key.shadow.radius = 4;
  sim.rig.root.traverse((o) => {
    if (!o.isMesh || (o.material && o.material.transparent)) return;
    o.castShadow = true;
    o.receiveShadow = true;
  });

  window.addEventListener("resize", () => {
    vw = window.innerWidth;
    vh = window.innerHeight;
    sim.setWorld({ w: vw, h: vh });
  });

  // ── Pointer: click / double-click / drag ─────────────────────────────────
  // The window only takes the mouse while it's over him or his bubble (Swift
  // toggles that), so presses here are meant for us.
  const inBox = (e) => {
    const b = sim.hitBox();
    return e.clientX >= b.x && e.clientX <= b.x + b.w && e.clientY >= b.y && e.clientY <= b.y + b.h;
  };
  let press = null; // {x, y, dragging}
  let clickTimer = 0;
  let dragging = false;
  window.addEventListener("pointerdown", (e) => {
    if (e.target.closest && e.target.closest("#bubble")) return; // bubble buttons handle themselves
    if (!inBox(e)) return;
    if (e.button === 2) {
      post({ type: "click", button: 2, mode: sim.s.mode });
      return;
    }
    press = { x: e.clientX, y: e.clientY, dragging: false };
  });
  window.addEventListener("pointermove", (e) => {
    if (!press) return;
    if (!press.dragging && Math.hypot(e.clientX - press.x, e.clientY - press.y) > 6) {
      press.dragging = true;
      dragging = true;
      hideBubble();
      sim.grab(e.clientX, e.clientY);
      post({ type: "drag", on: true });
      clearTimeout(timer);
      cancelAnimationFrame(raf);
      schedule(60);
    }
    if (press.dragging) sim.dragTo(e.clientX, e.clientY);
  });
  window.addEventListener("pointerup", () => {
    if (!press) return;
    const wasDrag = press.dragging;
    press = null;
    if (wasDrag) {
      dragging = false;
      sim.drop();
      post({ type: "drag", on: false });
      return;
    }
    // Single vs double click: wait a beat before treating it as single.
    if (clickTimer) {
      clearTimeout(clickTimer);
      clickTimer = 0;
      post({ type: "dblclick" });
    } else {
      clickTimer = setTimeout(() => {
        clickTimer = 0;
        post({ type: "click", button: 0, mode: sim.s.mode });
      }, 260);
    }
  });
  window.addEventListener("contextmenu", (e) => e.preventDefault());

  // ── Speech bubble ────────────────────────────────────────────────────────
  // Text only (textContent) — nothing Swift or the model sends can inject markup.
  const style = document.createElement("style");
  style.textContent = `
    #bubble { position:absolute; left:0; top:0; max-width:300px; min-width:170px; padding:12px 14px 12px;
      border-radius:18px; background:rgba(14,14,20,.9); color:#fff;
      font:500 13px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;
      box-shadow:0 12px 32px rgba(0,0,0,.35), inset 0 0 0 1px rgba(255,255,255,.08);
      -webkit-backdrop-filter:blur(18px); backdrop-filter:blur(18px);
      transform-origin:50% 100%; opacity:0; pointer-events:auto; will-change:transform,opacity;
      transition:opacity .18s ease; }
    #bubble.show { opacity:1; animation:pop .32s cubic-bezier(.2,1.4,.4,1); }
    @keyframes pop { from { transform:var(--pos) scale(.7); } to { transform:var(--pos) scale(1); } }
    #bubble::after { content:""; position:absolute; left:50%; bottom:-7px; width:14px; height:14px;
      margin-left:-7px; background:rgba(14,14,20,.9); transform:rotate(45deg); border-radius:3px; }
    #bubble .t { font-weight:650; font-size:13.5px; }
    #bubble .s { color:rgba(255,255,255,.62); font-size:12px; margin-top:3px; }
    #bubble .a { display:flex; flex-wrap:wrap; gap:6px; margin-top:10px; }
    #bubble button { font:600 11.5px -apple-system,sans-serif; color:#fff; border:0; border-radius:999px;
      padding:6px 11px; background:rgba(255,255,255,.12); cursor:pointer; }
    #bubble button:hover { background:rgba(255,255,255,.2); }
    #bubble button.p { background:linear-gradient(135deg,#3b6bff,#7d4dff); }
    #bubble .sw { display:flex; align-items:center; gap:5px; margin-top:10px; padding-top:9px;
      border-top:1px solid rgba(255,255,255,.1); font-size:11px; color:rgba(255,255,255,.55); }
    #bubble .sw .n { margin-right:auto; }
    #bubble .sw button { width:24px; height:24px; padding:0; border-radius:50%; font-size:11.5px; }
    #bubble .sw button.on { background:linear-gradient(135deg,#3b6bff,#7d4dff); box-shadow:0 0 0 2px rgba(157,140,255,.45); }
    #bubble .x { position:absolute; right:8px; top:6px; background:none; padding:2px 5px; color:rgba(255,255,255,.45); }
    #bubble .dots span { display:inline-block; width:5px; height:5px; margin-left:3px; border-radius:50%;
      background:#fff; opacity:.3; animation:dot 1s infinite; }
    #bubble .dots span:nth-child(2) { animation-delay:.15s } #bubble .dots span:nth-child(3) { animation-delay:.3s }
    @keyframes dot { 50% { opacity:1; transform:translateY(-2px); } }`;
  document.head.appendChild(style);
  const bubble = document.createElement("div");
  bubble.id = "bubble";
  bubble.style.display = "none";
  host.appendChild(bubble);
  let bubbleTimer = 0;
  let bubbleOn = false;
  const hideBubble = () => {
    bubbleOn = false;
    bubble.classList.remove("show");
    clearTimeout(bubbleTimer);
    bubbleTimer = setTimeout(() => {
      if (!bubbleOn) bubble.style.display = "none";
    }, 200);
  };
  /** {title, sub?, actions?: [{id, label, primary?}], ttl? seconds, dots?, kind?,
   *   avatars?: {current, items: [{id, name}]}, live?} — avatars adds the 1·2·3
   *   switcher; live updates an already-shown bubble without the pop. */
  const showBubble = (b) => {
    bubble.textContent = "";
    const t = document.createElement("div");
    t.className = "t";
    t.textContent = b.title || "";
    if (b.dots) {
      const d = document.createElement("span");
      d.className = "dots";
      d.append(document.createElement("span"), document.createElement("span"), document.createElement("span"));
      t.appendChild(d);
    }
    bubble.appendChild(t);
    if (b.sub) {
      const sub = document.createElement("div");
      sub.className = "s";
      sub.textContent = b.sub;
      bubble.appendChild(sub);
    }
    if (b.actions && b.actions.length) {
      const row = document.createElement("div");
      row.className = "a";
      b.actions.forEach((a) => {
        const btn = document.createElement("button");
        btn.textContent = a.label;
        if (a.primary) btn.className = "p";
        btn.addEventListener("click", (e) => {
          e.stopPropagation();
          post({ type: "action", id: a.id });
          hideBubble();
        });
        row.appendChild(btn);
      });
      bubble.appendChild(row);
    }
    if (b.avatars && b.avatars.items && b.avatars.items.length > 1) {
      const sw = document.createElement("div");
      sw.className = "sw";
      const cur = b.avatars.items.find((i) => i.id === b.avatars.current);
      const name = document.createElement("span");
      name.className = "n";
      name.textContent = `Avatar · ${cur ? cur.name : ""}`;
      sw.appendChild(name);
      b.avatars.items.forEach((it, i) => {
        const btn = document.createElement("button");
        btn.textContent = String(i + 1);
        btn.title = it.name;
        if (it.id === b.avatars.current) btn.className = "on";
        btn.addEventListener("mouseenter", () => (name.textContent = `Avatar · ${it.name}`));
        btn.addEventListener("mouseleave", () => (name.textContent = `Avatar · ${cur ? cur.name : ""}`));
        btn.addEventListener("click", (e) => {
          e.stopPropagation();
          if (it.id !== b.avatars.current) post({ type: "action", id: `avatar:${it.id}` });
          hideBubble();
        });
        sw.appendChild(btn);
      });
      bubble.appendChild(sw);
    }
    const x = document.createElement("button");
    x.className = "x";
    x.textContent = "✕";
    x.addEventListener("click", (e) => {
      e.stopPropagation();
      hideBubble();
    });
    bubble.appendChild(x);
    bubble.style.display = "block";
    const wasOn = bubbleOn;
    bubbleOn = true;
    // Live captions update in place; anything else pops in.
    if (!(b.live && wasOn)) {
      bubble.classList.remove("show");
      void bubble.offsetWidth; // restart the pop animation
      bubble.classList.add("show");
    }
    clearTimeout(bubbleTimer);
    if (b.ttl) bubbleTimer = setTimeout(hideBubble, b.ttl * 1000);
  };
  const placeBubble = (s) => {
    if (!bubbleOn) return;
    const w = bubble.offsetWidth;
    const h = bubble.offsetHeight;
    const headTop = vh - (s.y + 2.1 * SIZE);
    const x = Math.round(Math.min(Math.max(s.x - w / 2, 8), vw - w - 8));
    const y = Math.round(Math.max(headTop - h - 10, 8));
    const pos = `translate3d(${x}px, ${y}px, 0)`;
    bubble.style.setProperty("--pos", pos);
    if (!bubble.getAnimations || !bubble.getAnimations().length) bubble.style.transform = pos;
  };
  const bubbleBox = () => {
    if (!bubbleOn) return null;
    const r = bubble.getBoundingClientRect();
    return { x: r.left, y: r.top, w: r.width, h: r.height + 10 };
  };

  let paused = false;
  let eco = false; // energy saver: lower frame rates (Swift sends it on battery)
  let raf = 0;
  let last = performance.now();
  let reportIn = 0;
  let saveIn = 1;
  // Wake-ups, not drawing, were the real cost: requestAnimationFrame wakes
  // WebKit's content + GPU processes and the app's compositor 60x a second
  // even when nothing changes. So only use rAF when he needs 60fps (you're
  // handling him); otherwise a timer at 30 (walking) or 15 (standing).
  // The simulation's easing is frame-rate independent, so motion stays right.
  let timer = 0;
  const schedule = (fps) => {
    if (fps >= 60) raf = requestAnimationFrame(loop);
    else timer = setTimeout(() => loop(performance.now()), 1000 / fps);
  };
  const loop = (now) => {
    const dt = Math.min(0.1, (now - last) / 1000);
    last = now;
    if (paused) {
      timer = setTimeout(() => loop(performance.now()), 500);
      return;
    }
    sim.step(dt);
    const s = sim.s;
    const settling = Math.abs(s.swing) > 0.01 || Math.abs(s.swingV) > 0.05 || Math.abs(s.sq) > 0.005;
    let fps = dragging || settling || s.mode === "fall" || s.wWave > 0.05 || s.wDangle > 0.05 ? 60
      : s.mode === "walk" || Math.abs(s.vx) > 2 || s.mode === "held" || s.talkV > 0.02 || s.talk > 0
        || s.wDance > 0.02 || s.wCeleb > 0.02 || s.wPoint > 0.02 ? 30 : 15;
    // Energy saver (on battery): one notch down, except while you're dragging him.
    if (eco && !dragging) fps = fps >= 60 ? 30 : fps >= 30 ? 15 : 10;
    frameCamera(s);
    renderer.render(sim.scene, camera);
    placeBubble(s);
    reportIn -= dt;
    if (reportIn <= 0) {
      reportIn = dragging ? 1 / 30 : 1 / 10;
      post({
        type: "state", box: sim.hitBox(), bubble: bubbleBox(), dragging,
        mode: s.mode, perch: s.perch && s.perch.id, attending: s.attending,
        // Swift polls the window list fast only while windows matter to him.
        needsWorld: !!s.perch || !!s.goal || s.mode === "land",
      });
    }
    saveIn -= dt;
    if (saveIn <= 0) {
      saveIn = 1;
      try {
        localStorage.setItem("dreamer:state", JSON.stringify(sim.snapshot()));
      } catch (e) {
        /* ignore */
      }
    }
    schedule(fps);
  };
  schedule(15);

  const api = {
    sim,
    setWorld: (o) => sim.setWorld(o),
    setPerches: (l) => sim.setPerches(l),
    intent: (id, reason) => sim.intent(id, reason),
    attend: (p) => sim.attend(p),
    command: (c) => sim.command(c),
    setFollow: (on) => sim.setFollow(on),
    setTalk: (v) => sim.setTalk(v),
    setMusic: (on, bpm) => sim.setMusic(on, bpm),
    react: (k) => sim.react(k),
    setSleepy: (on) => sim.setSleepy(on),
    setEco: (on) => {
      eco = !!on;
    },
    setHover: (on) => {
      sim.setHover(on);
      clearTimeout(timer);
      cancelAnimationFrame(raf);
      schedule(on ? 60 : 30);
    },
    bubble: (b) => (b ? showBubble(b) : hideBubble()),
    setMouse: (x, y) => sim.setMouse(x, y),
    setPaused(on) {
      paused = !!on;
      host.style.opacity = paused ? "0" : "1";
    },
    /** Dev: a close-up portrait (facing you, or at `yaw`) as a PNG data URL. */
    closeup(yaw = 0.35) {
      const r = sim.rig;
      const keep = { scale: r.root.scale.x, pos: r.root.position.clone(), rx: r.root.rotation.x, q: r.pitch.quaternion.clone() };
      const cam = new THREE.OrthographicCamera(0, BOX, BOX, 0, 1, 4000);
      cam.position.z = 2000;
      r.root.scale.setScalar(260);
      r.root.rotation.x = 0.12;
      r.pitch.quaternion.setFromEuler(new THREE.Euler(0, yaw, 0));
      r.root.position.set(BOX / 2, -250, 0); // frame head and shoulders
      r.root.updateMatrixWorld(true);
      sim.aimLights(BOX / 2, 120, 260 / SIZE);
      renderer.setClearColor(0x2a2d38, 1);
      renderer.render(sim.scene, cam);
      const url = renderer.domElement.toDataURL("image/png");
      renderer.setClearColor(0x000000, 0);
      r.root.scale.setScalar(keep.scale);
      r.root.position.copy(keep.pos);
      r.root.rotation.x = keep.rx;
      r.pitch.quaternion.copy(keep.q);
      post({ type: "closeup", data: url });
      return url.length;
    },
    // Manual stepping for tests (same idea as the reference's window.__dreamer).
    run(sec, fps = 60) {
      for (let i = 0; i < sec * fps; i += 1) sim.step(1 / fps);
      frameCamera(sim.s);
      renderer.render(sim.scene, camera);
      return { mode: sim.s.mode, x: Math.round(sim.s.x), y: Math.round(sim.s.y) };
    },
  };
  window.dreamer = api;
  post({ type: "ready", w: vw, h: vh });
  return api;
}
