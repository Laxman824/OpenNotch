// Interactive pixel-matrix background: a dot grid like the display around the notch.
// Dots light up under the cursor; a ripple leaves the notch every few seconds; clicks send ripples too.
(() => {
  const cv = document.getElementById("pixels");
  if (!cv) return;
  const c = cv.getContext("2d");
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const GLOW = [[92, 140, 255], [176, 102, 255], [255, 102, 171], [255, 158, 77]];
  let W = 0, H = 0, D = 1, GAP = 26, cols = 0, rows = 0;
  const mouse = { x: -9999, y: -9999, tx: -9999, ty: -9999 };
  const ripples = [];
  const fit = () => {
    D = Math.min(2, devicePixelRatio || 1);
    W = innerWidth; H = innerHeight;
    GAP = W < 700 ? 22 : 26;
    cv.width = W * D; cv.height = H * D; cv.style.width = W + "px"; cv.style.height = H + "px";
    cols = Math.ceil(W / GAP) + 1; rows = Math.ceil(H / GAP) + 1;
  };
  fit(); addEventListener("resize", fit);
  addEventListener("pointermove", (e) => { mouse.tx = e.clientX; mouse.ty = e.clientY; if (mouse.x < -999) { mouse.x = e.clientX; mouse.y = e.clientY; } }, { passive: true });
  addEventListener("pointerleave", () => { mouse.tx = mouse.ty = -9999; });
  addEventListener("pointerdown", (e) => {
    if (e.target.closest("a, button, iframe, canvas#bigPuff, .site-notch, video, details, input")) return;
    ripples.push({ x: e.clientX, y: e.clientY, t0: performance.now(), hue: ripples.length % 4, speed: 620 });
  });
  window.notchRipple = (hue = 1) => ripples.push({ x: W / 2, y: 0, t0: performance.now(), hue, speed: 520 });
  let last = 0, visible = true;
  document.addEventListener("visibilitychange", () => (visible = !document.hidden));
  const draw = (now) => {
    requestAnimationFrame(draw);
    if (!visible || now - last < 30) return;   // ~30 fps is plenty for a background
    last = now;
    mouse.x += (mouse.tx - mouse.x) * 0.18; mouse.y += (mouse.ty - mouse.y) * 0.18;
    c.setTransform(D, 0, 0, D, 0, 0);
    c.clearRect(0, 0, W, H);
    const live = ripples.filter((r) => (now - r.t0) / 1000 * r.speed < Math.hypot(W, H));
    ripples.length = 0; ripples.push(...live);
    const R = 190, R2 = R * R;
    for (let j = 0; j < rows; j++) {
      const y = j * GAP + (GAP / 2);
      for (let i = 0; i < cols; i++) {
        const x = i * GAP + (j % 2 ? GAP / 2 : 0);
        // base: faint, a touch brighter under the notch
        const top = Math.max(0, 1 - Math.hypot((x - W / 2) / 420, y / 260));
        let a = 0.055 + top * 0.12, s = 1.3, col = null, ca = 0;
        // cursor light
        const dx = x - mouse.x, dy = y - mouse.y, d2 = dx * dx + dy * dy;
        if (d2 < R2) {
          const k = 1 - Math.sqrt(d2) / R;
          const g = GLOW[Math.floor(((Math.atan2(dy, dx) + Math.PI) / (2 * Math.PI)) * 4 + now / 2400) % 4];
          col = g; ca = k * k * 0.9; s += k * 1.8;
        }
        // ripples
        for (const r of ripples) {
          const rad = (now - r.t0) / 1000 * r.speed;
          const dist = Math.abs(Math.hypot(x - r.x, y - r.y) - rad);
          if (dist < 46) {
            const fade = Math.max(0, 1 - rad / 1400);
            const k = (1 - dist / 46) * fade;
            if (k * 0.8 > ca) { col = GLOW[r.hue]; ca = k * 0.8; }
            s += k * 1.3;
          }
        }
        if (col) {
          c.fillStyle = `rgba(${col[0]},${col[1]},${col[2]},${Math.min(1, a + ca)})`;
        } else c.fillStyle = `rgba(255,255,255,${a})`;
        c.fillRect(x - s / 2, y - s / 2, s, s);
      }
    }
  };
  if (reduce) { requestAnimationFrame((n) => { last = -1e9; draw(n); }); }
  else {
    requestAnimationFrame(draw);
    setTimeout(() => window.notchRipple(1), 600);
    setInterval(() => { if (scrollY < innerHeight) window.notchRipple(Math.floor(Math.random() * 4)); }, 4200);
  }
})();
