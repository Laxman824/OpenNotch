// Headless behaviour test for the desktop Dreamer: runs the real simulation
// (createSim) with no renderer. `node opennotch/desktop/test/sim.mjs`
// The rig paints its gingham onto a canvas — stub just enough of one.
globalThis.document = {
  createElement: () => ({
    width: 0, height: 0,
    getContext: () => new Proxy({}, { get: () => () => {} }),
  }),
};
const { createSim } = await import("../dreamer.js");

let failed = 0;
const check = (ok, msg) => { if (!ok) { failed += 1; console.log("FAIL", msg); } };
const W = 1710, H = 1080, FLOOR = 70, CEIL = 32;

// ── 1. Ten minutes of wandering over moving, appearing and closing windows ──
{
  const events = [];
  const sim = createSim({ vw: W, vh: H, pace: "lively", post: (m) => events.push(m) });
  sim.setWorld({ w: W, h: H, floor: FLOOR, ceil: CEIL });
  let wins = [
    { id: 1, x1: 200, x2: 900, top: 300 },
    { id: 2, x1: 950, x2: 1600, top: 520 },
    { id: 3, x1: 400, x2: 700, top: 760 },
  ];
  sim.setPerches(wins);
  const s = sim.s;
  let minX = 1e9, maxX = -1e9, maxY = -1e9, minY = 1e9, minV = 1e9, maxV = 0, nan = false;
  let perchedFrames = 0, rodeOK = true, rideChecks = 0;
  const dt = 1 / 60;
  for (let i = 0; i < 60 * 600; i += 1) {
    const t = i * dt;
    // Window 1 drifts (someone dragging it) — he must ride it.
    wins[0] = { ...wins[0], top: 300 + 80 * Math.sin(t * 0.3), x1: 200 + 60 * Math.sin(t * 0.2), x2: 900 + 60 * Math.sin(t * 0.2) };
    // Window 3 closes and reopens every 90s.
    const w3open = Math.floor(t / 90) % 2 === 0;
    sim.setPerches(w3open ? wins : wins.filter((w) => w.id !== 3));
    sim.step(dt);
    if (![s.x, s.y, s.vx, s.vy].every(Number.isFinite)) nan = true;
    minX = Math.min(minX, s.x); maxX = Math.max(maxX, s.x);
    minY = Math.min(minY, s.y); maxY = Math.max(maxY, s.y);
    if (s.mode === "fly") { minV = Math.min(minV, s.v); maxV = Math.max(maxV, s.v); }
    if (s.perch && (s.mode === "idle" || s.mode === "walk")) {
      perchedFrames += 1;
      const r = (w3open ? wins : wins.filter((w) => w.id !== 3)).find((w) => String(w.id) === s.perch.id);
      if (r) { rideChecks += 1; if (Math.abs(s.y - (H - r.top)) > 0.5) rodeOK = false; }
    }
  }
  const perches = events.filter((e) => e.type === "perch");
  const modes = new Set(events.filter((e) => e.type === "mode").map((e) => e.mode));
  console.log(`10 min: x ${minX.toFixed(0)}..${maxX.toFixed(0)}  y ${minY.toFixed(0)}..${maxY.toFixed(0)}  flight v ${minV.toFixed(0)}..${maxV.toFixed(0)}  perch landings ${perches.length}  perched ${(perchedFrames / 600 / 60 * 100).toFixed(0)}% of time  modes ${[...modes].join(",")}`);
  check(!nan, "position went NaN");
  check(minX >= 30 && maxX <= W - 30, `left the screen horizontally (${minX}..${maxX})`);
  check(minY >= FLOOR - 0.01, `went below the Dock line (${minY})`);
  check(maxY <= H - CEIL - 60 + 0.01, `flew into the menu bar (${maxY})`);
  check(perches.length >= 3, `rarely perched on windows (${perches.length})`);
  check(rideChecks > 0 && rodeOK, "didn't ride a moving window");
  check(["takeoff", "fly", "land", "launch", "walk", "idle"].every((m) => modes.has(m)), "missing behaviour modes");
  check(minV >= 69 && maxV <= 361, "flight speed outside the tuned clamp");
}

// ── 2. His window closes under him → he springs off, doesn't hover in mid-air ──
{
  const sim = createSim({ vw: W, vh: H, pace: "lively" });
  sim.setWorld({ w: W, h: H, floor: FLOOR, ceil: CEIL });
  sim.setPerches([{ id: 9, x1: 300, x2: 1000, top: 400 }]);
  const s = sim.s;
  sim.intent(9, "test");
  let landed = false;
  for (let i = 0; i < 60 * 30 && !landed; i += 1) { sim.step(1 / 60); landed = s.perch && s.perch.id === "9" && s.mode === "idle"; }
  check(landed, "never landed on the intended window");
  sim.setPerches([]); // window closed
  sim.step(1 / 60);
  check(s.perch === null && s.mode === "launch", `didn't spring off a closed window (mode ${s.mode})`);
}

// ── 3. Attend: Ledge is working → he comes to the notch and hovers; release lets him go ──
{
  const sim = createSim({ vw: W, vh: H, pace: "calm" });
  sim.setWorld({ w: W, h: H, floor: FLOOR, ceil: CEIL });
  const s = sim.s;
  for (let i = 0; i < 60 * 3; i += 1) sim.step(1 / 60); // standing somewhere
  const notch = { x: W / 2, y: 150, side: 130 }; // y from the top
  sim.attend(notch);
  let reachedAt = null, hoverFrames = 0;
  for (let i = 0; i < 60 * 25; i += 1) {
    sim.step(1 / 60);
    const d = Math.hypot(s.x - (notch.x + (s.x < notch.x ? -130 : 130)), s.y - (H - notch.y));
    if (reachedAt === null && d < 60) reachedAt = i / 60;
    if (s.attending) hoverFrames += 1;
  }
  console.log(`attend: reached the notch in ${reachedAt === null ? "never" : reachedAt.toFixed(1) + "s"}, hovering ${(hoverFrames / 60).toFixed(1)}s of ${(25 - (reachedAt || 0)).toFixed(1)}s`);
  check(reachedAt !== null && reachedAt < 12, "didn't reach the notch within 12s");
  check(hoverFrames / 60 > 25 - (reachedAt || 25) - 3, "didn't stay hovering by the notch");
  sim.attend(null);
  let down = false;
  for (let i = 0; i < 60 * 40 && !down; i += 1) { sim.step(1 / 60); down = s.mode === "idle" || s.mode === "walk"; }
  check(down, "never came back down after being released");
}

// ── 4. Desktop Ledge: walk only, big and cute ──
{
  const events = [];
  const sim = createSim({ vw: W, vh: H, pace: "calm", walkOnly: true, px: 88, cute: true, post: (m) => events.push(m) });
  sim.setWorld({ w: W, h: H, floor: FLOOR, ceil: CEIL });
  sim.setPerches([{ id: 1, x1: 200, x2: 900, top: 300 }]); // must be ignored
  sim.intent(1, "focus");
  sim.command("takeoff");
  const s = sim.s;
  let offFloor = false, minX = 1e9, maxX = -1e9, walkT = 0, idleT = 0;
  const flightModes = new Set(["takeoff", "launch", "fly", "land"]);
  let flew = false;
  for (let i = 0; i < 60 * 300; i += 1) {
    sim.step(1 / 60);
    if (Math.abs(s.y - FLOOR) > 0.01) offFloor = true;
    if (flightModes.has(s.mode)) flew = true;
    minX = Math.min(minX, s.x); maxX = Math.max(maxX, s.x);
    if (s.mode === "walk") walkT += 1 / 60; else idleT += 1 / 60;
  }
  console.log(`walker 5 min: x ${minX.toFixed(0)}..${maxX.toFixed(0)}  walking ${walkT.toFixed(0)}s / idle ${idleT.toFixed(0)}s`);
  check(!flew, "walker took off");
  check(!offFloor, "walker left the floor");
  check(walkT > 30 && idleT > 30, "walker should both stroll and pause");
  check(minX >= 30 && maxX <= W - 30, "walker left the screen");

  // Ledge needs you: walk to the notch, stand, look up; then carry on.
  sim.attend({ x: W / 2, y: 150, side: 190 });
  let arrivedAt = null, standing = 0;
  for (let i = 0; i < 60 * 30; i += 1) {
    sim.step(1 / 60);
    if (s.attending) { standing += 1 / 60; if (arrivedAt === null) arrivedAt = i / 60; }
  }
  console.log(`walker attend: arrived in ${arrivedAt === null ? "never" : arrivedAt.toFixed(1) + "s"}, standing ${standing.toFixed(1)}s, lookUp ${s.lookUp.toFixed(2)}, mode ${s.mode}`);
  check(arrivedAt !== null && arrivedAt < 20, "walker didn't reach the notch in 20s");
  check(Math.abs(s.x - W / 2) < 190 && s.mode === "idle" && s.lookUp > 0.9, "walker isn't standing under the notch looking up");
  sim.attend(null);
  let moved = false;
  const x0 = s.x;
  for (let i = 0; i < 60 * 30 && !moved; i += 1) { sim.step(1 / 60); moved = Math.abs(s.x - x0) > 40; }
  check(moved, "walker never resumed wandering after the notch closed");
}

// ── 5. Interactions: hover → stop, face you, wave; drag → dangle; drop → fall and land ──
{
  const events = [];
  const sim = createSim({ vw: W, vh: H, pace: "calm", walkOnly: true, px: 88, cute: true, post: (m) => events.push(m) });
  sim.setWorld({ w: W, h: H, floor: FLOOR, ceil: CEIL });
  const s = sim.s;
  sim.command("walk");
  for (let i = 0; i < 60; i += 1) sim.step(1 / 60);
  sim.setHover(true);
  let peakWave = 0;
  for (let i = 0; i < 60 * 2; i += 1) { sim.step(1 / 60); peakWave = Math.max(peakWave, s.wWave); }
  check(s.mode === "idle" && Math.abs(s.vx) < 3, `hover didn't stop him (mode ${s.mode}, vx ${s.vx.toFixed(1)})`);
  check(Math.abs(s.yaw) < 0.1, `hover didn't turn him to face you (yaw ${s.yaw.toFixed(2)})`);
  check(peakWave > 0.9, "he didn't wave on hover");
  for (let i = 0; i < 60 * 3; i += 1) sim.step(1 / 60);
  check(s.wWave < 0.1, "he kept waving forever");
  sim.setHover(false);

  sim.grab(900, 500); // pointer at (900, 500) from the top
  let minY = 1e9;
  for (let i = 0; i < 60; i += 1) { sim.step(1 / 60); minY = Math.min(minY, s.y); }
  const feetTarget = H - 500 - 1.55 * 88;
  check(s.mode === "held" && Math.abs(s.x - 900) < 5 && Math.abs(s.y - feetTarget) < 5, `didn't follow the drag (${s.x.toFixed(0)}, ${s.y.toFixed(0)})`);
  check(s.wDangle > 0.9, "not dangling while held");
  sim.dragTo(1200, 300);
  for (let i = 0; i < 20; i += 1) sim.step(1 / 60);
  sim.drop();
  let landedAt = null, below = false;
  for (let i = 0; i < 60 * 5; i += 1) {
    sim.step(1 / 60);
    if (s.y < FLOOR - 0.01) below = true;
    if (landedAt === null && events.some((e) => e.type === "landed")) landedAt = i / 60;
  }
  console.log(`drag & drop: fell to the floor in ${landedAt === null ? "never" : landedAt.toFixed(2) + "s"}, now ${s.mode} at x ${s.x.toFixed(0)}`);
  check(landedAt !== null && landedAt < 2 && !below, "drop didn't land cleanly on the floor");
  check(s.mode === "idle" || s.mode === "walk", "didn't resume after landing");
}

// ── 6. The bee avatar: builds, walks, flutters, never flies ──
{
  const sim = createSim({ vw: W, vh: H, pace: "calm", walkOnly: true, px: 88, cute: true, avatar: "bee" });
  sim.setWorld({ w: W, h: H, floor: FLOOR, ceil: CEIL });
  const s = sim.s;
  const wing = sim.rig.spine.children.find((c) => c.isGroup && c.userData.side === 1);
  check(!!wing && typeof sim.rig.tick === "function", "bee has no wings / tick");
  let flew = false, nan = false, wMin = 9, wMax = -9;
  for (let i = 0; i < 60 * 120; i += 1) {
    sim.step(1 / 60);
    if (s.mode === "fly" || s.mode === "takeoff") flew = true;
    if (![s.x, s.y].every(Number.isFinite)) nan = true;
    if (wing) { wMin = Math.min(wMin, wing.rotation.y); wMax = Math.max(wMax, wing.rotation.y); }
  }
  console.log(`bee: wings swing ${(wMax - wMin).toFixed(2)} rad, mode ${s.mode}`);
  check(!flew && !nan, "bee flew or went NaN");
  check(wMax - wMin > 0.2, "bee wings don't flutter");
  let hidden = 0;
  sim.rig.root.traverse((o) => { if (o.isMesh && o.material === sim.rig.mats.beard && o.visible) hidden += 1; });
  check(hidden === 0, "bee shows beard parts");
}

// ── 7. The cat avatar: builds, walks, tail sways, no human hair/headphones ──
{
  const sim = createSim({ vw: W, vh: H, pace: "calm", walkOnly: true, px: 88, cute: true, avatar: "cat" });
  sim.setWorld({ w: W, h: H, floor: FLOOR, ceil: CEIL });
  const s = sim.s;
  const tail = sim.rig.hips.children.find((c) => c.userData.tail);
  check(!!tail && typeof sim.rig.tick === "function", "cat has no tail / tick");
  let flew = false, nan = false, tMin = 9, tMax = -9;
  for (let i = 0; i < 60 * 120; i += 1) {
    sim.step(1 / 60);
    if (s.mode === "fly" || s.mode === "takeoff") flew = true;
    if (![s.x, s.y].every(Number.isFinite)) nan = true;
    if (tail) { tMin = Math.min(tMin, tail.rotation.y); tMax = Math.max(tMax, tail.rotation.y); }
  }
  console.log(`cat: tail sways ${(tMax - tMin).toFixed(2)} rad, mode ${s.mode}`);
  check(!flew && !nan, "cat flew or went NaN");
  check(tMax - tMin > 0.5, "cat tail doesn't sway");
  let human = 0;
  sim.rig.root.traverse((o) => {
    if (o.isMesh && o.visible && (o.material === sim.rig.mats.hair || o.material === sim.rig.mats.phones)) human += 1;
  });
  check(human === 0, `cat shows ${human} hair/headphone parts`);
}

// ── 8. Drag physics: swing while held, throw, wall bounce, squash, settle ──
{
  const events = [];
  const sim = createSim({ vw: W, vh: H, pace: "calm", walkOnly: true, px: 88, cute: true, post: (m) => events.push(m) });
  sim.setWorld({ w: W, h: H, floor: FLOOR, ceil: CEIL });
  const s = sim.s;
  for (let i = 0; i < 60; i += 1) sim.step(1 / 60);
  sim.grab(800, 500);
  for (let i = 0; i < 30; i += 1) sim.step(1 / 60);
  // Whip the pointer right, then stop dead: he should swing.
  let maxSwing = 0;
  for (let i = 0; i < 12; i += 1) { sim.dragTo(800 + i * 40, 500); sim.step(1 / 60); maxSwing = Math.max(maxSwing, Math.abs(s.swing)); }
  for (let i = 0; i < 40; i += 1) { sim.step(1 / 60); maxSwing = Math.max(maxSwing, Math.abs(s.swing)); }
  console.log(`drag physics: swing ${maxSwing.toFixed(2)} rad while held`);
  check(maxSwing > 0.08 && maxSwing <= 0.45, `swing ${maxSwing.toFixed(2)} not human-range (0.08–0.45)`);
  // Throw hard to the right: must hit the wall, come back, land, and settle.
  for (let i = 0; i < 6; i += 1) { sim.dragTo(1260 + i * 70, 400); sim.step(1 / 60); }
  sim.drop();
  const vThrow = s.vx;
  let hitWall = false, maxSq = 0, nan = false, below = false, landedAt = null;
  for (let i = 0; i < 60 * 6; i += 1) {
    sim.step(1 / 60);
    if (s.vx < 0) hitWall = true;
    maxSq = Math.max(maxSq, s.sq);
    if (![s.x, s.y, s.swing, s.sq].every(Number.isFinite)) nan = true;
    if (s.y < FLOOR - 0.01 || s.x < 30 || s.x > W - 30) below = true;
    if (landedAt === null && events.some((e) => e.type === "landed")) landedAt = i / 60;
  }
  console.log(`throw: vx ${vThrow.toFixed(0)}, wall bounce ${hitWall}, landed ${landedAt === null ? "never" : landedAt.toFixed(2) + "s"}, squash ${maxSq.toFixed(2)}, now swing ${s.swing.toFixed(3)} sq ${s.sq.toFixed(3)}`);
  check(vThrow > 300 && vThrow <= 750, "release didn't carry (bounded) pointer momentum");
  check(hitWall, "thrown at the wall but never bounced off it");
  check(landedAt !== null && landedAt < 4 && !below && !nan, "throw didn't land cleanly inside the screen");
  check(maxSq > 0.02 && maxSq <= 0.1, "landing squash missing or cartoonish");
  check(Math.abs(s.swing) < 0.01 && Math.abs(s.sq) < 0.01, "didn't settle upright after landing");
}

// ── 9. Talking mouth (hands-free): opens with the voice level on every avatar ──
for (const avatar of ["ledge", "bee", "cat"]) {
  const sim = createSim({ vw: W, vh: H, pace: "calm", walkOnly: true, px: 88, cute: true, avatar });
  const mouthScales = () => {
    const out = [];
    sim.rig.root.traverse((o) => { if (o.isMesh && o.userData.sy !== undefined) out.push(o.scale.y / o.userData.sy); });
    return out;
  };
  check(mouthScales().length > 0, `${avatar}: no mouth registered`);
  sim.setTalk(1);
  for (let i = 0; i < 20; i += 1) sim.step(1 / 60);
  const open = Math.min(...mouthScales());
  sim.setTalk(0);
  for (let i = 0; i < 30; i += 1) sim.step(1 / 60);
  const closed = Math.max(...mouthScales());
  check(open > 2.5 && closed < 1.05, `${avatar}: mouth open ${open.toFixed(2)} / closed ${closed.toFixed(2)}`);
}
console.log("talk: mouths open and close on all three avatars");

// ── 10. Music: he dances when idle, faces you, moves change, stops after ──
{
  const sim = createSim({ vw: W, vh: H, pace: "calm", walkOnly: true, post: () => {} });
  sim.setWorld({ w: W, h: H, floor: FLOOR, ceil: CEIL });
  const s = sim.s;
  const dt = 1 / 30;
  for (let i = 0; i < 30 * 5; i += 1) sim.step(dt);
  sim.setMusic(true, 120);
  let danceT = 0, idleT = 0, nan = false, armMin = 1e9, armMax = -1e9, maxDanceYaw = 0;
  const moves = new Set();
  for (let i = 0; i < 30 * 90; i += 1) {
    sim.step(dt);
    if (s.mode === "idle") idleT += dt;
    if (s.wDance > 0.9) { danceT += dt; moves.add(s.danceMove); }
    const z = sim.rig.arms.R.sh.rotation.z;
    if (!Number.isFinite(z) || !Number.isFinite(s.x)) nan = true;
    if (s.wDance > 0.9) { armMin = Math.min(armMin, z); armMax = Math.max(armMax, z); }
    // Facing you once he's been dancing a moment (the turn itself eases in).
    if (s.wDance > 0.99) maxDanceYaw = Math.max(maxDanceYaw, Math.abs(s.yaw));
  }
  check(!nan, "dance: NaN in pose");
  check(danceT > 45, `dance: only danced ${danceT.toFixed(0)}s of 90s with music`);
  check(moves.size >= 2, `dance: only ${moves.size} move(s) used`);
  check(armMax - armMin > 0.5, `dance: arms barely move (${(armMax - armMin).toFixed(2)} rad)`);
  check(maxDanceYaw < 0.3, `dance: not facing you while dancing (yaw up to ${maxDanceYaw.toFixed(2)})`);
  sim.setMusic(false);
  for (let i = 0; i < 30 * 3; i += 1) sim.step(dt);
  check(s.wDance < 0.05, `dance: still dancing after the music stopped (${s.wDance.toFixed(2)})`);
  console.log(`dance: ${danceT.toFixed(0)}s of 90s dancing (idle ${idleT.toFixed(0)}s), moves ${[...moves].join(",")}, arm swing ${(armMax - armMin).toFixed(2)} rad`);
}

// ── 11. Reactions: celebrate, point, doze (and hover wakes him) ──────────
{
  const sim = createSim({ vw: W, vh: H, pace: "calm", walkOnly: true, post: () => {} });
  sim.setWorld({ w: W, h: H, floor: FLOOR, ceil: CEIL });
  const s = sim.s;
  const dt = 1 / 30;
  const run = (sec) => { for (let i = 0; i < sec * 30; i += 1) sim.step(dt); };
  run(3);
  sim.react("celebrate");
  let peak = 0, armUp = -1e9;
  for (let i = 0; i < 30; i += 1) { sim.step(dt); peak = Math.max(peak, s.wCeleb); armUp = Math.max(armUp, sim.rig.arms.L.sh.rotation.z); }
  check(peak > 0.9, `celebrate: weight only ${peak.toFixed(2)}`);
  check(armUp > 2, `celebrate: arms not up (${armUp.toFixed(2)})`);
  run(3);
  check(s.react === null && s.wCeleb < 0.05, `celebrate: didn't finish (react ${s.react}, w ${s.wCeleb.toFixed(2)})`);

  sim.react("point");
  run(8);
  check(s.wPoint > 0.9 || s.mode !== "idle", `point: weight ${s.wPoint.toFixed(2)} in ${s.mode}`);
  sim.react(null);
  run(2);
  check(s.wPoint < 0.05, `point: still pointing after clear (${s.wPoint.toFixed(2)})`);

  sim.setSleepy(true);
  let walked = 0;
  for (let i = 0; i < 60 * 30; i += 1) { sim.step(dt); if (s.mode === "walk") walked += dt; }
  check(s.wSleep > 0.9, `sleep: weight ${s.wSleep.toFixed(2)}`);
  check(walked < 3, `sleep: walked ${walked.toFixed(1)}s while dozing`);
  sim.setHover(true);
  run(1);
  sim.setHover(false);
  run(3);
  check(!s.sleepy && s.wSleep < 0.1, `sleep: hover didn't wake him (sleepy ${s.sleepy}, w ${s.wSleep.toFixed(2)})`);
  sim.setSleepy(true);
  check(!s.sleepy, "sleep: dozed straight back off after being woken");
  console.log(`reactions: celebrate peak ${peak.toFixed(2)}, point ok, slept (walked ${walked.toFixed(1)}s), hover wakes`);
}

console.log(failed === 0 ? "desktop dreamer: all checks pass" : `desktop dreamer: ${failed} FAILED`);
process.exit(failed ? 1 : 0);
