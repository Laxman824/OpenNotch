// Puff, OpenNotch's notch character — a JS port of PuffCanvas (App/Sources/OpenNotch/Character.swift).
// Draws into whatever 2D context is current in `ctx`; Puff.mount() adds the poke / pet / gaze brain.
let ctx = null;
const FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Inter", system-ui, sans-serif';
const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
const PUFF_TOP = "#6B8CFF", PUFF_MID = "#BD6BFF", PUFF_BOT = "#FF7AB3";
const INK = "#1A1229", BLUSH = "#FF739E", YELLOW = "#FFD60A";

// ── Puff (JS port of PuffCanvas in Character.swift) ──
// o: { mood, expr, squash, hop, sway, gaze:{x,y}, boost }
function puff(cx, cy, s, t, o = {}) {
  const mood = o.mood || "idle", expr = o.expr || null;
  const happy = mood === "happy" || expr === "celebrate" || expr === "love";
  const breathe = Math.sin(t * 1.9) * 0.018;
  const sq = (o.squash || 0) + breathe;
  const w = s * 0.80 * (1 + sq * 0.85), h = s * 0.68 * (1 - sq);
  const ground = cy + s * 0.40;
  const lift = (o.hop || 0) * s * 0.55 + (happy && !o.hop ? Math.abs(Math.sin(t * 7)) * s * 0.03 : 0);
  const bx = cx - w / 2, by = ground - h - lift, bmx = cx, bmy = by + h / 2;
  const sway = (o.sway || 0) + (mood === "listening" ? 0.06 * Math.sin(t * 1.2) : 0);
  ctx.save();
  ctx.translate(bmx, by + h); ctx.rotate(sway); ctx.translate(-bmx, -(by + h));
  // halo
  const r = Math.max(w, h) * 0.8;
  let g = ctx.createRadialGradient(bmx, bmy, w * 0.3, bmx, bmy, r);
  g.addColorStop(0, "rgba(107,140,255,0.32)"); g.addColorStop(1, "rgba(107,140,255,0)");
  ctx.fillStyle = g; ctx.beginPath(); ctx.arc(bmx, bmy, r, 0, Math.PI * 2); ctx.fill();
  // sprout
  {
    const base = { x: bmx, y: by + h * 0.04 };
    const angle = sway * 1.8 + Math.sin(t * 1.6) * 0.10 + (mood === "working" ? Math.sin(t * 9) * 0.25 : 0);
    const len = s * 0.15;
    const tip = { x: base.x + Math.sin(angle) * len, y: base.y - Math.cos(angle) * len };
    ctx.strokeStyle = "#5CD185"; ctx.lineWidth = Math.max(1.2, s * 0.035); ctx.lineCap = "round";
    ctx.beginPath(); ctx.moveTo(base.x, base.y); ctx.quadraticCurveTo(base.x, base.y - len * 0.6, tip.x, tip.y); ctx.stroke();
    const busy = mood === "thinking" || mood === "working";
    const glow = busy ? 0.6 + 0.4 * Math.sin(t * 5) : 0;
    for (const side of [-1, 1]) {
      ctx.save(); ctx.translate(tip.x, tip.y); ctx.rotate(angle + side * 0.9);
      const lw = s * 0.12, lh = s * 0.065, x0 = side > 0 ? 0 : -lw;
      const lg = ctx.createLinearGradient(x0, -lh / 2, x0 + lw, lh / 2);
      lg.addColorStop(0, "#8CF29E"); lg.addColorStop(1, "#40B87A");
      ctx.fillStyle = lg; ctx.beginPath(); ctx.ellipse(x0 + lw / 2, 0, lw / 2, lh / 2, 0, 0, Math.PI * 2); ctx.fill();
      if (glow > 0) { ctx.fillStyle = `rgba(158,237,255,${0.25 * glow})`; ctx.beginPath(); ctx.ellipse(x0 + lw / 2, 0, lw * 0.7, lh * 0.9, 0, 0, Math.PI * 2); ctx.fill(); }
      ctx.restore();
    }
  }
  // body
  const rad = Math.min(w, h) * 0.47;
  const body = () => { ctx.beginPath(); ctx.roundRect(bx, by, w, h, rad); };
  g = ctx.createLinearGradient(0, by, 0, by + h);
  g.addColorStop(0, PUFF_TOP); g.addColorStop(0.5, PUFF_MID); g.addColorStop(1, PUFF_BOT);
  ctx.fillStyle = g; body(); ctx.fill();
  g = ctx.createRadialGradient(bmx, by + h * 0.35, w * 0.25, bmx, by + h * 0.35, w * 0.75);
  g.addColorStop(0, "rgba(0,0,0,0)"); g.addColorStop(1, "rgba(0,0,0,0.18)");
  ctx.fillStyle = g; body(); ctx.fill();
  // jelly: light through the bottom, a soft core, a rim light on top (as in Character.swift)
  g = ctx.createRadialGradient(bmx, by + h * 0.84, 0, bmx, by + h * 0.84, w * 0.34);
  g.addColorStop(0, "rgba(255,190,220,0.55)"); g.addColorStop(1, "rgba(255,122,179,0)");
  ctx.fillStyle = g; ctx.beginPath(); ctx.ellipse(bmx, by + h * 0.81, w * 0.32, h * 0.15, 0, 0, Math.PI * 2); ctx.fill();
  g = ctx.createRadialGradient(bmx, by + h * 0.42, 0, bmx, by + h * 0.42, w * 0.42);
  g.addColorStop(0, "rgba(255,255,255,0.14)"); g.addColorStop(1, "rgba(255,255,255,0)");
  ctx.fillStyle = g; body(); ctx.fill();
  g = ctx.createLinearGradient(0, by, 0, by + h * 0.45);
  g.addColorStop(0, "rgba(255,255,255,0.42)"); g.addColorStop(1, "rgba(255,255,255,0)");
  ctx.strokeStyle = g; ctx.lineWidth = Math.max(1, s * 0.018); body(); ctx.stroke();
  ctx.fillStyle = "rgba(255,255,255,0.32)";
  ctx.beginPath(); ctx.ellipse(bx + w * 0.33, by + h * 0.18, w * 0.17, h * 0.1, 0, 0, Math.PI * 2); ctx.fill();
  ctx.fillStyle = "rgba(255,255,255,0.45)";
  ctx.beginPath(); ctx.arc(bx + w * 0.79, by + h * 0.16 + w * 0.03, w * 0.03, 0, Math.PI * 2); ctx.fill();
  // eyes
  let look = o.gaze || { x: 0, y: 0 };
  if (mood === "thinking") look = { x: Math.sin(t * 1.3) * 0.7, y: -0.75 };
  if (mood === "working") look = { x: Math.sin(t * 2.6) * 0.55, y: 0.35 };
  const eyeY = bmy - h * 0.02 + look.y * h * 0.08;
  const spread = w * 0.2, boost = (o.boost || 1) * (expr === "surprised" ? 1.25 : 1);
  const ew = w * 0.18 * boost, eh = w * 0.23 * boost, lw = Math.max(1.2, s * 0.045);
  const period = 3.8, cyc = Math.floor(t / period), ph = t - cyc * period;
  const blinking = !o.noBlink && (ph > period - 0.12 || (cyc % 4 === 1 && ph > period - 0.38 && ph < period - 0.27));
  ctx.strokeStyle = INK; ctx.fillStyle = INK; ctx.lineCap = "round";
  for (const side of [-1, 1]) {
    const persp = 1 + 0.10 * look.x * side;
    const ex = bmx + side * spread + look.x * w * 0.10, ey = eyeY;
    const ew2 = ew * persp, eh2 = eh * persp;
    const arc = (up, k = 0.45) => {
      ctx.lineWidth = lw; ctx.strokeStyle = INK; ctx.beginPath();
      const yy = ey + (up ? eh * 0.12 : -eh * 0.05);
      ctx.moveTo(ex - ew2 / 2, yy); ctx.quadraticCurveTo(ex, ey + (up ? -eh * k : eh * k), ex + ew2 / 2, yy); ctx.stroke();
    };
    if (expr === "dizzy") {
      ctx.lineWidth = lw * 0.8; ctx.beginPath();
      for (let i = 0; i <= 40; i++) {
        const k = i / 40, a = k * 2.4 * 2 * Math.PI + t * 8 * side, rr = k * ew * 0.55;
        const px = ex + Math.cos(a) * rr, py = ey + Math.sin(a) * rr;
        i ? ctx.lineTo(px, py) : ctx.moveTo(px, py);
      }
      ctx.stroke();
    } else if (expr === "love") {
      heart(ex, ey, ew2 * 1.25, BLUSH);
      ctx.fillStyle = "rgba(255,255,255,0.8)"; ctx.beginPath(); ctx.arc(ex - ew2 * 0.2, ey - eh2 * 0.15, ew * 0.11, 0, Math.PI * 2); ctx.fill();
    } else if (expr === "celebrate" || mood === "happy") {
      arc(true, 0.55);
    } else if (blinking) {
      arc(false, 0.15);
    } else {
      ctx.fillStyle = INK; ctx.beginPath(); ctx.ellipse(ex, ey, ew2 / 2, eh2 / 2, 0, 0, Math.PI * 2); ctx.fill();
      // iris glow in the lower half: sparkly, coloured eyes
      ctx.save(); ctx.beginPath(); ctx.ellipse(ex, ey, ew2 / 2, eh2 / 2, 0, 0, Math.PI * 2); ctx.clip();
      const ig = ctx.createRadialGradient(ex, ey + eh2 / 2 - eh * 0.12, 0, ex, ey + eh2 / 2 - eh * 0.12, ew * 0.62);
      ig.addColorStop(0, "rgba(158,237,255,0.75)"); ig.addColorStop(1, "rgba(158,237,255,0)");
      ctx.fillStyle = ig; ctx.fillRect(ex - ew2, ey - eh2, ew2 * 2, eh2 * 2); ctx.restore();
      const big = ew * 0.36, small = ew * 0.16;
      ctx.fillStyle = "rgba(255,255,255,0.95)"; ctx.beginPath(); ctx.arc(ex - big * 0.15 + big / 2, ey - eh2 / 2 + eh * 0.14 + big / 2, big / 2, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = "rgba(255,255,255,0.7)"; ctx.beginPath(); ctx.arc(ex - ew2 / 2 + ew * 0.2 + small / 2, ey + eh2 / 2 - eh * 0.34 + small / 2, small / 2, 0, Math.PI * 2); ctx.fill();
    }
    const cheekA = happy ? 0.75 : 0.42, cw = ew * 1.1, ch = eh * 0.42;
    ctx.fillStyle = `rgba(255,115,158,${cheekA})`;
    ctx.beginPath(); ctx.ellipse(ex + side * ew * 0.45, ey + eh * 0.55 + ch / 2, cw / 2, ch / 2, 0, 0, Math.PI * 2); ctx.fill();
  }
  // mouth
  const my = eyeY + eh * 0.82, mw = w * 0.11;
  ctx.fillStyle = INK; ctx.strokeStyle = INK;
  if (expr === "celebrate" || expr === "love" || mood === "happy") {
    ctx.beginPath(); ctx.moveTo(bmx - mw, my - eh * 0.05); ctx.quadraticCurveTo(bmx, my + eh * 0.6, bmx + mw, my - eh * 0.05); ctx.closePath(); ctx.fill();
    ctx.fillStyle = "#FF8099"; ctx.beginPath(); ctx.ellipse(bmx, my + eh * 0.21, mw * 0.45, eh * 0.09, 0, 0, Math.PI * 2); ctx.fill();
  } else if (expr === "dizzy") {
    const rr = mw * (0.55 + 0.15 * Math.sin(t * 9));
    ctx.beginPath(); ctx.ellipse(bmx, my + rr * 0.65, rr, rr * 0.65, 0, 0, Math.PI * 2); ctx.fill();
  } else if (expr === "surprised" || mood === "alert") {
    const rr = mw * 0.42; ctx.beginPath(); ctx.ellipse(bmx, my + rr * 1.2, rr, rr * 1.2, 0, 0, Math.PI * 2); ctx.fill();
  } else {
    ctx.lineWidth = lw * 0.8; ctx.beginPath(); ctx.moveTo(bmx - mw * 0.55, my); ctx.quadraticCurveTo(bmx, my + eh * 0.32, bmx + mw * 0.55, my); ctx.stroke();
  }
  ctx.restore();
  // floating extras (unrotated)
  if (expr === "dizzy") {
    for (let i = 0; i < 3; i++) {
      const a = t * 4 + i * 2.094;
      star(bmx + Math.cos(a) * w * 0.55, by - s * 0.04 + Math.sin(a) * s * 0.07, s * 0.06, `rgba(255,214,10,${0.6 + 0.4 * Math.sin(a)})`);
    }
  } else if (expr === "celebrate") {
    for (let i = 0; i < 4; i++) {
      const a = i * Math.PI / 2 + Math.PI / 4, k = (t * 1.5) % 1;
      sparkle(bmx + Math.cos(a) * w * (0.5 + 0.25 * k), bmy + Math.sin(a) * h * (0.55 + 0.25 * k), s * 0.06, `rgba(158,237,255,${1 - k})`);
    }
  } else if (expr === "love") {
    for (let i = 0; i < 3; i++) {
      const k = ((t * 0.7) + i / 3) % 1;
      heart(bmx + (i - 1) * w * 0.35 + Math.sin(k * 6 + i) * s * 0.04, by - k * s * 0.6, s * (0.09 + 0.03 * i), `rgba(255,115,158,${(1 - k) * 0.9})`);
    }
  } else if (mood === "alert") {
    ctx.fillStyle = YELLOW; ctx.font = `800 ${s * 0.26}px ${FONT}`; ctx.textAlign = "center";
    ctx.fillText("!", bx + w * 0.98, by + h * 0.05 + Math.sin(t * 10) * s * 0.02);
  } else if (mood === "thinking") {
    for (let i = 0; i < 3; i++) {
      ctx.fillStyle = `rgba(158,237,255,${0.5 + 0.4 * Math.sin(t * 3 + i)})`;
      ctx.beginPath(); ctx.arc(bx + w * (0.95 + i * 0.1), by - s * (0.02 + i * 0.07), s * (0.025 + i * 0.008), 0, Math.PI * 2); ctx.fill();
    }
  }
}
function heart(x, y, sz, color) {
  ctx.save(); ctx.translate(x, y); ctx.fillStyle = color; ctx.beginPath();
  const s = sz / 2;
  ctx.moveTo(0, s * 0.85);
  ctx.bezierCurveTo(-s * 1.2, s * 0.05, -s * 0.75, -s * 1.0, 0, -s * 0.35);
  ctx.bezierCurveTo(s * 0.75, -s * 1.0, s * 1.2, s * 0.05, 0, s * 0.85);
  ctx.fill(); ctx.restore();
}
function star(x, y, r, color) {
  ctx.save(); ctx.translate(x, y); ctx.fillStyle = color; ctx.beginPath();
  for (let i = 0; i < 10; i++) { const a = -Math.PI / 2 + i * Math.PI / 5, rr = i % 2 ? r * 0.45 : r; ctx.lineTo(Math.cos(a) * rr, Math.sin(a) * rr); }
  ctx.closePath(); ctx.fill(); ctx.restore();
}
function sparkle(x, y, r, color) {
  ctx.save(); ctx.translate(x, y); ctx.fillStyle = color; ctx.beginPath();
  ctx.moveTo(0, -r); ctx.quadraticCurveTo(0, 0, r, 0); ctx.quadraticCurveTo(0, 0, 0, r);
  ctx.quadraticCurveTo(0, 0, -r, 0); ctx.quadraticCurveTo(0, 0, 0, -r); ctx.fill(); ctx.restore();
}


// ── Brain: poke → annoyed, 3 pokes in 1.6 s → dizzy, 4 stroke reversals in 1.6 s → love (same rules as the app)
const Puff = {
  mount(canvas, opts = {}) {
    const c2d = canvas.getContext("2d");
    const st = { expr: null, until: 0, pokes: [], revs: [], lastDir: 0, lastX: null, squash: 0, sv: 0, hop: 0, hv: 0,
      gaze: { x: 0, y: 0 }, gx: 0, gy: 0, mood: opts.mood || "idle", onReact: opts.onReact || (() => {}) };
    const size = () => { const r = canvas.getBoundingClientRect(); return { w: r.width, h: r.height }; };
    const fit = () => { const { w, h } = size(), d = Math.min(2, window.devicePixelRatio || 1); canvas.width = w * d; canvas.height = h * d; };
    fit(); window.addEventListener("resize", fit);
    const react = (e, ms) => { st.expr = e; st.until = performance.now() + ms; st.onReact(e); };
    canvas.addEventListener("pointerdown", () => {
      const now = performance.now();
      st.pokes = st.pokes.filter((p) => now - p < 1600); st.pokes.push(now);
      st.sv -= 6;                                            // squash
      if (st.pokes.length >= 3) { react("dizzy", 2200); st.pokes = []; } else react("annoyed", 1100);
    });
    canvas.addEventListener("pointermove", (ev) => {
      if (ev.buttons) return;
      const x = ev.clientX, now = performance.now();
      if (st.lastX !== null) {
        const dx = x - st.lastX;
        if (Math.abs(dx) > 2) {
          const dir = Math.sign(dx);
          if (st.lastDir && dir !== st.lastDir) { st.revs = st.revs.filter((r) => now - r < 1600); st.revs.push(now); }
          st.lastDir = dir;
          if (st.revs.length >= 4 && st.expr !== "love") { react("love", 2600); st.revs = []; st.hv = 3.2; }
        }
      }
      st.lastX = x;
    });
    canvas.addEventListener("dblclick", () => { react("celebrate", 1600); st.hv = 4; });
    window.addEventListener("pointermove", (ev) => {
      const r = canvas.getBoundingClientRect();
      st.gaze = { x: clamp((ev.clientX - (r.left + r.width / 2)) / 500, -1, 1), y: clamp((ev.clientY - (r.top + r.height / 2)) / 400, -1, 1) };
    }, { passive: true });
    let last = performance.now(), visible = true;
    new IntersectionObserver((es) => { visible = es[0].isIntersecting; }).observe(canvas);
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const frame = (now) => {
      requestAnimationFrame(frame);
      if (!visible) return;
      const dt = Math.min(0.05, (now - last) / 1000); last = now;
      if (st.expr && now > st.until) st.expr = null;
      // springs
      st.sv += (-st.squash * 180 - st.sv * 12) * dt; st.squash += st.sv * dt;
      st.hv -= 18 * dt; st.hop = Math.max(0, st.hop + st.hv * dt); if (st.hop === 0 && st.hv < 0) st.hv = 0;
      st.gx += (st.gaze.x - st.gx) * Math.min(1, dt * 8); st.gy += (st.gaze.y - st.gy) * Math.min(1, dt * 8);
      const { w, h } = size(), d = canvas.width / Math.max(1, w);
      c2d.setTransform(d, 0, 0, d, 0, 0); c2d.clearRect(0, 0, w, h);
      ctx = c2d;
      const t = reduce ? 0 : now / 1000;
      const s = Math.min(w, h) * (opts.scale || 0.8);
      puff(w / 2, h / 2 + (opts.dy || 0) * s, s, t, { mood: opts.moodFn ? opts.moodFn() : st.mood, expr: st.expr, squash: clamp(st.squash, -0.3, 0.3), hop: st.hop, gaze: { x: st.gx, y: st.gy } });
    };
    requestAnimationFrame(frame);
    return st;
  },
};
window.Puff = Puff;
