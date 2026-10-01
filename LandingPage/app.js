// OpenNotch landing page behaviour: scroll reveals, the live notch demo, voice typewriter,
// Puff instances and the live 3D companion stage.
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── Reveal on scroll ──
const io = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } }), { threshold: 0.15, rootMargin: "0px 0px -40px" });
$$(".reveal").forEach((el, i) => { el.style.transitionDelay = `${(i % 4) * 60}ms`; io.observe(el); });

// ── Card spotlight follows the cursor ──
$$(".card, .wcard").forEach((c) => c.addEventListener("pointermove", (e) => {
  const r = c.getBoundingClientRect();
  c.style.setProperty("--mx", `${e.clientX - r.left}px`); c.style.setProperty("--my", `${e.clientY - r.top}px`);
}));

// ── Clock in the fake menu bar ──


// ── Puffs ──
let notchMood = "idle";
Puff.mount($("#earPuff"), { scale: 0.9, moodFn: () => notchMood });
Puff.mount($("#panelPuff"), { scale: 0.9, moodFn: () => notchMood });
Puff.mount($("#finalPuff"), { scale: 0.75 });
$$(".mini-puff").forEach((c) => Puff.mount(c, { scale: 0.85, mood: c.dataset.mood }));
const say = $("#puffSay");
let sayT = 0;
const sayIt = (s) => { say.textContent = s; say.classList.add("on"); clearTimeout(sayT); sayT = setTimeout(() => say.classList.remove("on"), 1400); };
Puff.mount($("#bigPuff"), { scale: 0.62, onReact: (e) => sayIt({ annoyed: "hey!", dizzy: "whoa…", love: "♥ hehe", celebrate: "yay!" }[e] || "hi!") });
setTimeout(() => sayIt("hi! poke me"), 1200);

// ── The live notch: ear activities while closed, a working chat when opened ──
const notch = $("#notch"), earRight = $("#earRight"), pBody = $("#pBody"), pStatus = $("#pStatus");
const wave = '<span class="ear-wave">' + "<i></i>".repeat(6) + "</span>";
let timerLeft = 25 * 60;
const tnum = () => `${Math.floor(timerLeft / 60)}:${String(timerLeft % 60).padStart(2, "0")}`;
// Hero: cycle through the app's real live activities.
const DEMO = [
  { mood: "happy", html: () => `<span class="ear-art"></span>${wave}` },
  { mood: "idle", html: () => `<span class="ear-ring" style="--p:72%"></span><div><small style="color:#FF9E4D">TIMER</small><span class="tnum">${tnum()}</span></div>` },
  { mood: "alert", cls: "approval", html: () => `<div><small style="color:var(--yellow)">NEEDS YOUR OK</small>Run command</div>` },
  { mood: "listening", cls: "listening", html: () => `<div><small style="color:var(--cyan)">LISTENING</small>“Hey Ledge…”</div>${wave}` },
];
// Every other section: the notch shows what you're reading.
const SECTION_EARS = {
  film: { mood: "happy", html: () => `<div><small style="color:var(--g3)">NOW SHOWING</small>The film</div>` },
  tools: { mood: "idle", html: () => `<div><small style="color:var(--g1)">14 TOOLS</small>one hover away</div>` },
  voice: { mood: "listening", cls: "listening", html: () => `<div><small style="color:var(--cyan)">LISTENING</small>Just say it</div>${wave}` },
  mcp: { mood: "working", html: () => `<div><small style="color:var(--green)">CONNECTORS</small>4 MCP servers live</div>` },
  local: { mood: "idle", html: () => `<span class="ear-lock"></span><div><small style="color:var(--green)">LOCAL</small>on this Mac</div>` },
  work: { mood: "working", html: () => `<div><small style="color:var(--cyan)">WORKING</small>Step 3/4</div>` },
  ai: { mood: "thinking", html: () => `<div><small style="color:var(--g2)">MODEL</small>your choice</div>` },
  puff: { mood: "happy", html: () => `<div><small style="color:var(--g3)">THAT'S ME</small>poke me ↓</div>` },
  buddies: { mood: "happy", html: () => `<span class="ear-art"></span>${wave}` },
  install: { mood: "idle", html: () => `<div><small style="color:var(--green)">FREE</small>v0.1 · MIT</div>` },
  final: { mood: "happy", html: () => `<div><small style="color:var(--g4)">READY</small>give it a job</div>` },
};
let earI = 0, open = false, hover = false, demoRun = 0, section = "demo";
function showEar() {
  const e = section === "demo" ? DEMO[earI % DEMO.length] : SECTION_EARS[section] || DEMO[0];
  notchMood = e.mood;
  earRight.innerHTML = e.html();
  notch.classList.toggle("approval", e.cls === "approval" && !open);
  notch.classList.toggle("listening", e.cls === "listening" && !open);
}
showEar();
setInterval(() => { if (!open && section === "demo") { earI++; showEar(); if (window.notchRipple) window.notchRipple(earI % 4); } }, 3400);
setInterval(() => { timerLeft = Math.max(0, timerLeft - 1); const n = $(".tnum", earRight); if (n) n.textContent = tnum(); }, 1000);
// Which section is on screen?
const secIO = new IntersectionObserver((es) => {
  es.forEach((e) => { if (e.isIntersecting && e.target.dataset.ear !== section) { section = e.target.dataset.ear; if (!open) showEar(); } });
}, { rootMargin: "-45% 0px -50% 0px" });
$$("[data-ear]").forEach((el) => secIO.observe(el));

function setOpen(v) {
  if (v === open) return;
  open = v;
  notch.classList.toggle("open", v);
  notch.classList.remove("approval", "listening");
  $("#panel").setAttribute("aria-hidden", String(!v));
  if (v) runDemo(); else { demoRun++; showEar(); }
}
const row = (html, cls = "") => { const d = document.createElement("div"); d.className = cls; d.innerHTML = html; pBody.appendChild(d); return d; };
async function runDemo() {
  const id = ++demoRun;
  const alive = () => id === demoRun;
  pBody.innerHTML = ""; notchMood = "idle"; pStatus.textContent = "Ready";
  await sleep(450); if (!alive()) return;
  row("Plan my day", "bubble");
  notchMood = "thinking"; pStatus.textContent = "Thinking…";
  await sleep(700); if (!alive()) return;
  const tools = [["#FF6B6B", "Checked your calendar", "calendar_events"], ["#FF9E4D", "Read your reminders", "reminders_list"], ["#5C8CFF", "Got the weather", "weather"]];
  notchMood = "working";
  for (let i = 0; i < tools.length; i++) {
    pStatus.textContent = `Step ${i + 1}/3`;
    const [c, v, code] = tools[i];
    const r = row(`<i style="--c:${c}"></i>${v}<code>${code}</code><span class="ok" style="opacity:0;transition:opacity .2s"></span>`, "trow");
    await sleep(420); if (!alive()) return;
    $(".ok", r).style.opacity = 1;
  }
  pStatus.textContent = "Writing…";
  const p = row("", "ans");
  const answer = "Clear morning until your 11:00 design review. Rain after 4 — take an umbrella. Three reminders are due; start with the invoice.";
  for (let i = 0; i <= answer.length; i += 2) { if (!alive()) return; p.textContent = answer.slice(0, i); await sleep(16); }
  notchMood = "happy"; pStatus.textContent = "Done · 4 tools · 2.1 s";
}
notch.addEventListener("pointerenter", () => { hover = true; setOpen(true); });
notch.addEventListener("pointerleave", () => { hover = false; setTimeout(() => { if (!hover) setOpen(false); }, 500); });
notch.addEventListener("focus", () => setOpen(true));
notch.addEventListener("blur", () => setOpen(false));
notch.addEventListener("click", (e) => { if (!e.target.closest("a")) setOpen(true); });
$$(".p-nav a").forEach((a) => a.addEventListener("click", () => { hover = false; setOpen(false); notch.blur(); }));
document.addEventListener("keydown", (e) => { if (e.key === "Escape") { setOpen(false); notch.blur(); } });

// ── Voice section: words light up as they're "spoken" ──
const PHRASES = ["“Hey Ledge, play something chill.”", "“Start a 25-minute focus timer.”", "“What's on my calendar today?”", "“Summarise this page.”", "“Draft a reply to Sam.”", "“Yes.”"];
const sayText = $("#sayText");
(async () => {
  let k = 0;
  for (;;) {
    const words = PHRASES[k++ % PHRASES.length].split(" ");
    sayText.innerHTML = words.map((w) => `<span class="w">${w}</span>`).join(" ");
    const ws = $$(".w", sayText);
    for (const w of ws) { await sleep(reduce ? 0 : 230); w.classList.add("on"); }
    await sleep(1600);
  }
})();

// ── Stats count up ──
$$("[data-count]").forEach((el) => {
  const to = +el.dataset.count, suf = el.dataset.suffix || "";
  if (!to || reduce) return;
  const ob = new IntersectionObserver(([e]) => {
    if (!e.isIntersecting) return; ob.disconnect();
    const t0 = performance.now();
    const step = (now) => { const k = Math.min(1, (now - t0) / 1200); el.textContent = Math.round(to * (1 - Math.pow(1 - k, 3))) + suf; if (k < 1) requestAnimationFrame(step); };
    requestAnimationFrame(step);
  });
  ob.observe(el);
});

// ── Copy buttons ──
$$(".copy").forEach((b) => b.addEventListener("click", async () => {
  try { await navigator.clipboard.writeText(b.dataset.copy); b.textContent = "Copied"; setTimeout(() => (b.textContent = "Copy"), 1400); } catch { /* clipboard blocked */ }
}));

// ── Film: start playing (muted) when it scrolls into view ──
const film = $("#filmVideo");
if (film && !reduce) new IntersectionObserver(([e]) => {
  if (e.isIntersecting && film.paused && !film.dataset.touched) { film.preload = "auto"; film.muted = true; film.play().catch(() => {}); }
}, { threshold: 0.5 }).observe(film);
film?.addEventListener("volumechange", () => (film.dataset.touched = "1"));

// ── Live 3D companion stage (the app's real three.js character) ──
const stage = $("#stageFrame");
if (stage) {
  const ctl = () => stage.contentWindow && stage.contentWindow.dreamer;
  let current = "bee", dancing = false;
  const pick = (av) => {
    current = av; dancing = false; $("#danceBtn").classList.remove("on");
    $$(".av").forEach((b) => b.classList.toggle("on", b.dataset.av === av));
    stage.src = `companion/stage.html?avatar=${av}`;
  };
  $$(".av").forEach((b) => b.addEventListener("click", () => pick(b.dataset.av)));
  $("#danceBtn").addEventListener("click", () => { const d = ctl(); if (!d) return; dancing = !dancing; d.setMusic(dancing, 118); $("#danceBtn").classList.toggle("on", dancing); });
  $("#dropBtn").addEventListener("click", () => { const d = ctl(); if (d) d.entrance(stage.clientWidth / 2); });
  $("#cheerBtn").addEventListener("click", () => { const d = ctl(); if (d) d.react("celebrate"); });
  // Load it only when it's about to be seen.
  new IntersectionObserver(([e], ob) => { if (e.isIntersecting) { pick(current); ob.disconnect(); } }, { rootMargin: "300px" }).observe(stage);
}

// ── Bee on the hero floor (live 3D) — paused while scrolled away ──
const heroBuddy = $("#heroBuddy");
if (heroBuddy) {
  heroBuddy.src = "companion/stage.html?avatar=bee&floor=34&delay=900";
  new IntersectionObserver(([e]) => { const d = heroBuddy.contentWindow && heroBuddy.contentWindow.dreamer; if (d) d.setPaused(!e.isIntersecting); }).observe(heroBuddy);
}

// ── Manifesto: words light up as you scroll through it ──
const mf = $("#manifesto");
if (mf) {
  const EM = new Set(["plan", "keep", "play", "guard", "wave", "hello."]);
  mf.innerHTML = mf.textContent.trim().split(/\s+/).map((w) => `<span class="w${EM.has(w.replace(/[,.—]/g, "").toLowerCase()) || w === "hello." ? " em" : ""}">${w}</span>`).join(" ");
  const ws = $$(".w", mf);
  const onScroll = () => {
    const r = mf.getBoundingClientRect();
    const p = Math.min(1, Math.max(0, (innerHeight * 0.85 - r.top) / (r.height + innerHeight * 0.35)));
    const n = Math.round(p * ws.length);
    ws.forEach((w, i) => w.classList.toggle("on", i < n));
  };
  addEventListener("scroll", onScroll, { passive: true }); onScroll();
}

// ── Pinned showcase: scroll drives the notch through the tools ──
const sc = $(".showcase");
if (sc) {
  const panes = $$(".bn-pane", sc), items = $$("#scList li"), tabs = $$(".bn-tabs i", sc), bar = $("#scBar"), big = $("#bigNotch");
  let cur = -1;
  const set = (i, p) => {
    if (i !== cur) {
      panes.forEach((el, k) => { el.classList.toggle("on", k === i); el.classList.toggle("gone", k < i); });
      items.forEach((el, k) => el.classList.toggle("on", k === i));
      tabs.forEach((el, k) => el.classList.toggle("on", k === i));
      cur = i;
      if (window.notchRipple) window.notchRipple(i % 4);
    }
    items[i] && items[i].style.setProperty("--p", `${Math.round(p * 100)}%`);
  };
  const onScroll = () => {
    const r = sc.getBoundingClientRect(), total = sc.offsetHeight - innerHeight;
    const p = Math.min(0.9999, Math.max(0, -r.top / total));
    const i = Math.floor(p * panes.length);
    set(i, (p * panes.length) % 1);
    bar.style.width = `${p * 100}%`;
  };
  addEventListener("scroll", onScroll, { passive: true }); onScroll();
  // 3D tilt toward the cursor
  if (!reduce) $("#scStage").addEventListener("pointermove", (e) => {
    const r = big.getBoundingClientRect();
    big.style.setProperty("--ry", `${((e.clientX - r.left) / r.width - 0.5) * 14}deg`);
    big.style.setProperty("--rx", `${-((e.clientY - r.top) / r.height - 0.5) * 10}deg`);
  });
  $("#scStage").addEventListener("pointerleave", () => { big.style.removeProperty("--rx"); big.style.removeProperty("--ry"); });
  // focus timer counts down while visible
  let left = 1500;
  setInterval(() => { if (cur === 4) { left = Math.max(0, left - 1); $("#bnClock").textContent = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`; } }, 1000);
  const dropW = () => { const d = $(".drop", sc); if (d) d.style.setProperty("--w", d.clientWidth / 2 + "px"); };
  dropW(); addEventListener("resize", dropW);
}

// ── Film: grows from a card to full-bleed as you scroll ──
const filmSec = $("#film");
if (filmSec) {
  const upd = () => {
    const r = filmSec.getBoundingClientRect(), total = filmSec.offsetHeight - innerHeight;
    const p = Math.min(1, Math.max(0, -r.top / (total * 0.75)));
    filmSec.style.setProperty("--fp", p.toFixed(4));
  };
  addEventListener("scroll", upd, { passive: true }); upd();
}

// ── Dock of tools with macOS-style magnification ──
const DOCK = [
  ["Files", "#6aa8ff,#2e6be6", '<path d="M3 7h6l2 2h10v10H3z" fill="#fff"/>'],
  ["Shell", "#2b2b30,#0d0d10", '<path d="M5 8l4 4-4 4M12 17h7" stroke="#fff" stroke-width="2.2" fill="none" stroke-linecap="round"/>'],
  ["Web", "#58c7ff,#1a7bea", '<circle cx="12" cy="12" r="8" stroke="#fff" stroke-width="2" fill="none"/><path d="M4 12h16M12 4c3 3 3 13 0 16M12 4c-3 3-3 13 0 16" stroke="#fff" stroke-width="1.6" fill="none"/>'],
  ["Mail", "#5fb8ff,#1d6ff2", '<rect x="3.5" y="6" width="17" height="12" rx="2" fill="#fff"/><path d="M4 7l8 6 8-6" stroke="#1d6ff2" stroke-width="1.8" fill="none"/>'],
  ["Notes", "#ffe27a,#f5c518", '<rect x="5" y="4" width="14" height="16" rx="2" fill="#fff"/><path d="M8 9h8M8 12.5h8M8 16h5" stroke="#c9a400" stroke-width="1.6"/>'],
  ["Calendar", "#ffffff,#e9e9ec", '<text x="12" y="9" font-size="5" text-anchor="middle" fill="#ff3b30" font-family="system-ui" font-weight="700">THU</text><text x="12" y="19.5" font-size="11" text-anchor="middle" fill="#111" font-family="system-ui" font-weight="600">2</text>'],
  ["Reminders", "#ffffff,#eeeeef", '<circle cx="7" cy="8" r="2" fill="#ff9500"/><circle cx="7" cy="12.5" r="2" fill="#007aff"/><circle cx="7" cy="17" r="2" fill="#ff3b30"/><path d="M11 8h8M11 12.5h8M11 17h8" stroke="#bbb" stroke-width="1.4"/>'],
  ["Contacts", "#c6a27a,#8f6a46", '<circle cx="12" cy="9.5" r="3.5" fill="#fff"/><path d="M5.5 19c1-4 12-4 13 0" fill="#fff"/>'],
  ["Weather", "#57b5ff,#2a6fd6", '<circle cx="9" cy="9" r="3.4" fill="#ffd60a"/><path d="M8 18h9a3 3 0 0 0 0-6 4.5 4.5 0 0 0-8.6 1.4A2.4 2.4 0 0 0 8 18z" fill="#fff"/>'],
  ["Screen", "#3a3a40,#16161a", '<path d="M4 8V5h3M17 5h3v3M20 16v3h-3M7 19H4v-3" stroke="#fff" stroke-width="2" fill="none"/><circle cx="12" cy="12" r="2.5" fill="#fff"/>'],
  ["Clipboard", "#9b8cff,#5b45e6", '<rect x="6" y="5" width="12" height="15" rx="2" fill="#fff"/><rect x="9" y="3.5" width="6" height="3" rx="1" fill="#d8d0ff"/>'],
  ["Timer", "#ffb15c,#ff7a1a", '<circle cx="12" cy="13" r="7" stroke="#fff" stroke-width="2" fill="none"/><path d="M12 13l3-3M10 3.5h4" stroke="#fff" stroke-width="2" stroke-linecap="round"/>'],
  ["Music", "#ff6b8b,#f72a59", '<path d="M10 17V7l9-2v10" stroke="#fff" stroke-width="2" fill="none"/><circle cx="8" cy="17" r="2.4" fill="#fff"/><circle cx="17" cy="15" r="2.4" fill="#fff"/>'],
  ["Memory", "#c58bff,#8a3cf0", '<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z" fill="#fff"/>'],
  ["Schedules", "#5ee0c0,#14a88a", '<circle cx="12" cy="12" r="8" fill="#fff"/><path d="M12 7v5l3.5 2" stroke="#14a88a" stroke-width="2" fill="none" stroke-linecap="round"/>'],
  ["MCP", "#2c2c33,#0f0f12", '<path d="M8 4v5M16 4v5M6 9h12v3a6 6 0 0 1-12 0zM12 18v3" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round"/>'],
];
const dock = $("#dock");
if (dock) {
  dock.innerHTML = DOCK.map(([l, g, svg], i) => `<div class="dk${i % 5 === 0 ? " dk-on" : ""}" data-label="${l}" style="--bg-i:linear-gradient(160deg,${g})"><svg viewBox="0 0 24 24" aria-hidden="true">${svg}</svg></div>`).join("");
  const icons = $$(".dk", dock);
  dock.addEventListener("pointermove", (e) => {
    icons.forEach((el) => {
      const r = el.getBoundingClientRect(), d = Math.abs(e.clientX - (r.left + r.width / 2));
      el.style.setProperty("--s", (1 + 0.75 * Math.max(0, 1 - d / 170) ** 2).toFixed(3));
    });
  });
  dock.addEventListener("pointerleave", () => icons.forEach((el) => el.style.setProperty("--s", 1)));
}

// ── Live agent run: thinking streams, plan checks itself off (loops while visible) ──
const runThink = $("#runThink"), runPlan = $$("#runPlan li"), runHead = $("#runHead"), runCount = $("#runCount");
if (runThink) {
  const THOUGHTS = [
    "They want a plan for today. I'll read the calendar first, then reminders, then the weather for their city…",
    "Three events: standup 9:30, design review 11:00, coffee at 3. Two reminders are due today.",
    "Rain after 4 pm. The coffee is at 3, so they'll beat it — suggest an umbrella for the walk back.",
    "Order: invoice before standup, review prep after. Keep it to four lines.",
  ];
  let visible = false;
  new IntersectionObserver(([e]) => (visible = e.isIntersecting)).observe(runThink);
  (async () => {
    for (;;) {
      if (!visible) { await sleep(400); continue; }
      runPlan.forEach((li) => (li.className = "")); runCount.textContent = "0/4";
      for (let step = 0; step < 4; step++) {
        runPlan[step].className = "doing"; runHead.textContent = step === 3 ? "Writing…" : "Thinking…"; runHead.classList.add("shim");
        const t = THOUGHTS[step]; runThink.textContent = "";
        for (let i = 0; i <= t.length; i += 2) { runThink.textContent = t.slice(0, i); await sleep(reduce ? 0 : 18); }
        await sleep(500);
        runPlan[step].className = "done"; runCount.textContent = `${step + 1}/4`;
      }
      runHead.classList.remove("shim"); runHead.textContent = "Thought for 6s";
      await sleep(2600);
    }
  })();
}

// ── Approval card: cursor comes in, presses Approve, it runs ──
const okCard = $("#okCard");
if (okCard) {
  const cur = $(".okcur");
  (async () => {
    for (;;) {
      okCard.classList.remove("approved", "press"); cur.style.left = "78%"; cur.style.top = "92%";
      await sleep(1600);
      const ap = $(".ap", okCard), box = okCard.parentElement.getBoundingClientRect(), r = ap.getBoundingClientRect();
      cur.style.left = `${((r.left + r.width / 2 - box.left) / box.width) * 100}%`; cur.style.top = `${((r.top + r.height / 2 - box.top) / box.height) * 100}%`;
      await sleep(900); okCard.classList.add("press"); await sleep(160); okCard.classList.remove("press"); okCard.classList.add("approved");
      await sleep(2800);
    }
  })();
}

// ── Schedule dial ticks ──
const ticks = $(".dial .ticks");
if (ticks) ticks.innerHTML = Array.from({ length: 60 }, (_, i) => {
  const a = (i / 60) * Math.PI * 2, hr = i % 5 === 0, r1 = hr ? 70 : 75;
  return `<line class="tick${hr ? " hr" : ""}" x1="${100 + Math.sin(a) * r1}" y1="${100 - Math.cos(a) * r1}" x2="${100 + Math.sin(a) * 80}" y2="${100 - Math.cos(a) * 80}"/>`;
}).join("");

// ── MCP beams: connectors → notch → your AI ──
const beam = $("#beam"), bsvg = $("#beamSvg");
if (beam && bsvg) {
  const draw = () => {
    const B = beam.getBoundingClientRect(), C = $("#bCenter .b-notch").getBoundingClientRect();
    const cx = C.left + C.width / 2 - B.left, cy = C.top + C.height / 2 - B.top;
    let html = '<defs><linearGradient id="bg1" x1="0" x2="1"><stop offset="0" stop-color="#9eedff" stop-opacity="0"/><stop offset=".5" stop-color="#9eedff"/><stop offset="1" stop-color="#b066ff"/></linearGradient></defs>';
    $$(".b-left .b-node", beam).forEach((n, i) => {
      const r = n.getBoundingClientRect(), x = r.right - B.left, y = r.top + r.height / 2 - B.top;
      const d = `M${x},${y} C${(x + cx) / 2},${y} ${(x + cx) / 2},${cy} ${C.left - B.left},${cy}`;
      html += `<path class="base" d="${d}"/><path class="pulse" d="${d}" pathLength="1000" stroke="url(#bg1)" style="animation-delay:${-i * 0.55}s"/>`;
    });
    const A = $("#bAI").getBoundingClientRect(), ax = A.left - B.left, ay = A.top + A.height / 2 - B.top, sx = C.right - B.left;
    const d2 = `M${sx},${cy} C${(sx + ax) / 2},${cy} ${(sx + ax) / 2},${ay} ${ax},${ay}`;
    html += `<path class="base" d="${d2}"/><path class="pulse" d="${d2}" pathLength="1000" stroke="url(#bg1)" style="animation-duration:1.6s"/><path class="pulse" d="${d2}" pathLength="1000" stroke="url(#bg1)" style="animation-duration:1.6s;animation-delay:-.8s"/>`;
    bsvg.innerHTML = html;
  };
  draw(); addEventListener("resize", draw); new ResizeObserver(draw).observe(beam);
  const AIS = [["Claude", "claude"], ["GPT", "openai"], ["Gemini", "googlegemini"], ["Llama", "meta"], ["on-device", "chip"]];
  let k = 0; const nm = $("#aiName"), lg = $("#aiLogo");
  const showAI = () => {
    nm.textContent = AIS[k][0]; lg.innerHTML = window.logoSVG(AIS[k][1], 34);
    [nm, lg].forEach((el) => { el.style.animation = "none"; void el.offsetWidth; el.style.animation = ""; });
  };
  showAI();
  setInterval(() => { k = (k + 1) % AIS.length; showAI(); }, 2200);
  Puff.mount($("#beamPuff"), { scale: 0.85, mood: "working" });
}
const orbitPuff = $("#orbitPuff");
if (orbitPuff) Puff.mount(orbitPuff, { scale: 0.6, mood: "happy" });

// ── Install terminal types itself when it scrolls into view ──
const term = $("#termBody");
if (term) {
  const LINES = [
    ["cmd", "git clone https://github.com/Laxman824/OpenNotch && cd OpenNotch"],
    ["dim", "Cloning into 'OpenNotch'… done."],
    ["cmd", "scripts/signing.sh"],
    ["ok", "✓ local signing identity ready — permissions survive rebuilds"],
    ["cmd", "scripts/build.sh --install --open"],
    ["dim", "Building OpenNotch… "],
    ["ok", "✓ installed · opening OpenNotch"],
    ["cmd", "cli/opennotch \"what's on my calendar?\""],
    ["dim", "↑ asked the notch"],
  ];
  const esc = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;");
  let started = false;
  new IntersectionObserver(async ([e]) => {
    if (!e.isIntersecting || started) return; started = true;
    let html = "";
    for (const [k, t] of LINES) {
      if (k === "cmd") {
        for (let i = 0; i <= t.length; i += 2) { term.innerHTML = html + `<span class="pr">❯</span> ${esc(t.slice(0, i))}<span class="caret"></span>`; await sleep(reduce ? 0 : 22); }
        html += `<span class="pr">❯</span> ${esc(t)}\n`; await sleep(250);
      } else { html += `<span class="${k}">${esc(t)}</span>\n`; term.innerHTML = html; await sleep(380); }
    }
    term.innerHTML = html + `<span class="pr">❯</span> <span class="caret"></span>`;
  }, { threshold: 0.4 }).observe(term);
}

// ── Provider logos in the orbit and the "ways to connect" list ──
const GLOWC = { claude: "rgba(217,119,87,.9)", openai: "rgba(255,255,255,.7)", googlegemini: "rgba(145,104,240,.9)", ollama: "rgba(255,255,255,.6)", meta: "rgba(45,136,255,.9)", openrouter: "rgba(139,140,246,.9)", lmstudio: "rgba(167,139,250,.9)", chip: "rgba(255,255,255,.6)" };
$$(".lchip[data-k]").forEach((el) => {
  const k = el.dataset.k;
  el.innerHTML = window.logoSVG(k) + `<em>${window.LOGOS[k].name}</em>`;
  el.style.setProperty("--glowc", GLOWC[k]);
  el.title = window.LOGOS[k].name;
});
$$(".wl").forEach((el) => {
  el.innerHTML = el.dataset.l.split(" ").map((k) => k === "groq" ? '<span><b class="t">groq</b></span>' : `<span>${window.logoSVG(k)}</span>`).join("");
});
