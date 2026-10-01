// The dreamer's body and poses. Built in metres (about 1.8 m tall, facing +z,
// y up); Dreamer.js scales it to pixels. Every pose is a flat bag of joint
// angles so poses can be blended by weight instead of swapped.
import * as THREE from "./three.module.js";

// Modelled on the owner's portrait (src/assets/hero-gaze/center.webp): warm
// brown skin, black quiff with tight sides, full short beard, grey gingham
// button-down, white over-ear headphones -- plus denim and navy sneakers.
// Dark mode only lifts the tones so they don't sink into the page.
export const PALETTE = {
  light: {
    skin: "#b8805a",
    lip: "#8f5540",
    teeth: "#f4f0ea",
    hair: "#15100d",
    beard: "#1b1411",
    brow: "#1d1512",
    checkLight: "#eef0f3",
    checkMid: "#c3c8d0",
    checkDark: "#8d96a3",
    phones: "#f2f2f0",
    cushion: "#c9cace",
    jeans: "#3b4d78",
    sole: "#f5f3ef",
    sneaker: "#27324d",
    eye: "#16110f",
    trail: "#6366f1",
    shadow: "#1b1b2f",
    // Desktop Ledge outfit (cute mode): the Ledge hoodie.
    hoodie: "#6f63e8",
    hoodieDeep: "#5b4fd6",
    string: "#f7f5ff",
    joggers: "#4b5060",
    sneakerCute: "#f6f6f8",
    soleCute: "#b9a8ff",
    stubble: "#2e1f18",
  },
  dark: {
    skin: "#c18760",
    lip: "#96593f",
    teeth: "#f4f0ea",
    hair: "#18120f",
    beard: "#1e1613",
    brow: "#201714",
    checkLight: "#f2f4f6",
    checkMid: "#c9ced5",
    checkDark: "#9aa2ae",
    phones: "#f4f4f2",
    cushion: "#cfd0d4",
    jeans: "#5268a0",
    sole: "#f5f3ef",
    sneaker: "#3a4970",
    eye: "#16110f",
    trail: "#e0e7ff",
    shadow: "#000000",
    hoodie: "#7d72f0",
    hoodieDeep: "#665ae0",
    string: "#f7f5ff",
    joggers: "#5a6072",
    sneakerCute: "#f6f6f8",
    soleCute: "#c3b5ff",
    stubble: "#2e1f18",
  },
};

const V2 = (x, y) => new THREE.Vector2(x, y);

// No CapsuleGeometry in three r135, so lathe one: r1 at the bottom, r2 at the
// top, which also gives tapered limbs for free.
const capsuleGeo = (r1, r2, len, seg = 6) => {
  const pts = [];
  for (let i = 0; i <= seg; i += 1) {
    const a = -Math.PI / 2 + (i / seg) * (Math.PI / 2);
    pts.push(V2(Math.cos(a) * r1, -len / 2 + Math.sin(a) * r1));
  }
  for (let i = 0; i <= seg; i += 1) {
    const a = (i / seg) * (Math.PI / 2);
    pts.push(V2(Math.cos(a) * r2, len / 2 + Math.sin(a) * r2));
  }
  return new THREE.LatheGeometry(pts, 18);
};

// Lathe with a slice missing at the front (phi = 0 faces +z): an open shirt.
const openShell = (pts, gap) =>
  new THREE.LatheGeometry(pts, 28, gap / 2, Math.PI * 2 - gap);

const mesh = (geo, mat, x = 0, y = 0, z = 0) => {
  const m = new THREE.Mesh(geo, mat);
  m.position.set(x, y, z);
  return m;
};

const group = (parent, x = 0, y = 0, z = 0) => {
  const g = new THREE.Group();
  g.position.set(x, y, z);
  parent.add(g);
  return g;
};

// Waist (y 0) to neck base (y 0.55): narrow waist, broad chest, sloped
// trapezius into the neck.
const TORSO = [
  [0.0, -0.02],
  [0.13, -0.02],
  [0.132, 0.08],
  [0.148, 0.2],
  [0.168, 0.32],
  [0.176, 0.4],
  [0.16, 0.46],
  [0.11, 0.51],
  [0.06, 0.545],
  [0.0, 0.55],
];

export const HIP_HEIGHT = 0.985;

/**
 * @param {object} pal  PALETTE.light / .dark
 * @param {{cute?: boolean, style?: "ledge"|"bee"|"cat"}} [opts]  cute: chibi
 *   proportions and face (desktop Ledge) — a bigger head, big glossy eyes with
 *   sparkles, rosy cheeks, a happy smile. Same person, same skeleton and poses;
 *   off = the original. style "bee": the second desktop avatar (implies cute) —
 *   a girl in a honey-bee outfit: black bob, antenna cap, amber eyes, wings.
 *   style "cat": the third — a black cat in a purple hoodie (hood up, ears
 *   through it), yellow cat-eye glasses, big green eyes, a swaying tail.
 */
export const buildRig = (pal, opts = {}) => {
  const bee = opts.style === "bee";
  const cat = opts.style === "cat";
  const cute = !!opts.cute || bee || cat;
  // The renderer outputs sRGB, so the palette's hex colours are converted to
  // linear first -- otherwise every colour comes out washed-out and pastel.
  const lin = (hex) => new THREE.Color(hex).convertSRGBToLinear();
  const std = (color, rough = 0.62) =>
    new THREE.MeshStandardMaterial({ color: lin(color), roughness: rough, metalness: 0 });
  // Gingham: a tiny tile of overlapping grey bands, repeated per part so the
  // checks stay roughly the same size on the torso and the sleeves.
  const ginghamTile = (() => {
    const c = document.createElement("canvas");
    c.width = 32;
    c.height = 32;
    const g = c.getContext("2d");
    g.fillStyle = pal.checkLight;
    g.fillRect(0, 0, 32, 32);
    g.fillStyle = pal.checkMid;
    g.fillRect(0, 0, 16, 32);
    g.fillRect(0, 0, 32, 16);
    g.fillStyle = pal.checkDark;
    g.fillRect(0, 0, 16, 16);
    return c;
  })();
  const textures = [];
  const gingham = (u, v, side) => {
    const t = new THREE.CanvasTexture(ginghamTile);
    t.wrapS = THREE.RepeatWrapping;
    t.wrapT = THREE.RepeatWrapping;
    t.repeat.set(u, v);
    t.encoding = THREE.sRGBEncoding;
    t.anisotropy = 4;
    textures.push(t);
    return new THREE.MeshStandardMaterial({
      map: t,
      roughness: 0.85,
      side: side || THREE.FrontSide,
    });
  };
  // Cute mode wears the Ledge hoodie + joggers; the original keeps the
  // gingham button-down and jeans. Chosen here so every mesh is built with
  // the right material (no swapping afterwards).
  //
  // Premium look (cute mode): physically based materials that respond to the
  // studio environment the page sets up — fleece and joggers get cloth
  // *sheen* (soft light at grazing angles, what makes fabric read as fabric),
  // hair and headphones get a clearcoat highlight, skin a faint velvet sheen.
  const phys = (color, o = {}) =>
    new THREE.MeshPhysicalMaterial({
      color: lin(color),
      roughness: o.rough ?? 0.6,
      metalness: 0,
      sheen: o.sheen ?? 0,
      sheenColor: o.sheenColor ? lin(o.sheenColor) : new THREE.Color(0x000000),
      sheenRoughness: o.sheenRough ?? 0.5,
      clearcoat: o.coat ?? 0,
      clearcoatRoughness: o.coatRough ?? 0.2,
      side: o.side || THREE.FrontSide,
    });
  const fleece = cute ? phys("#5a4bdc", { rough: 0.95, sheen: 0.8, sheenColor: "#b8aeff", sheenRough: 0.55 }) : null;
  const fleeceTwoSided = cute
    ? phys("#5a4bdc", { rough: 0.95, sheen: 0.8, sheenColor: "#b8aeff", sheenRough: 0.55, side: THREE.DoubleSide })
    : null;
  const mats = {
    // Slightly deeper, warmer skin in cute mode: filmic tone mapping lifts and
    // desaturates, and the likeness depends on keeping his warm brown tone.
    skin: cute ? phys("#9c5f3c", { rough: 0.55, sheen: 0.25, sheenColor: "#e8a47c", sheenRough: 0.7 }) : std(pal.skin, 0.55),
    lip: std(pal.lip, 0.5),
    teeth: std(pal.teeth, 0.4),
    hair: cute ? phys(pal.hair, { rough: 0.62, coat: 0.12, coatRough: 0.45 }) : std(pal.hair, 0.75),
    // Light stubble in cute mode: translucent shading, not a solid mass.
    beard: cute
      ? new THREE.MeshStandardMaterial({
          color: lin(pal.stubble), roughness: 1, transparent: true, opacity: 0.32, depthWrite: false,
        })
      : std(pal.beard, 0.9),
    brow: std(pal.brow, 0.8),
    shirt: cute ? fleece : gingham(34, 17),
    shirtTails: cute ? fleeceTwoSided : gingham(34, 4, THREE.DoubleSide),
    sleeve: cute ? fleece : gingham(13, 8),
    collar: cute ? phys("#4638c4", { rough: 0.95, sheen: 0.8, sheenColor: "#a89dff", sheenRough: 0.55 }) : gingham(10, 2),
    button: std(pal.checkLight, 0.4),
    phones: cute ? phys(pal.phones, { rough: 0.3, coat: 1, coatRough: 0.12 }) : std(pal.phones, 0.35),
    cushion: cute ? phys(pal.cushion, { rough: 0.8, sheen: 0.6, sheenColor: "#ffffff" }) : std(pal.cushion, 0.7),
    jeans: cute ? phys("#3a3f4d", { rough: 0.92, sheen: 0.6, sheenColor: "#8d93a6", sheenRough: 0.6 }) : std(pal.jeans, 0.85),
    sole: cute ? phys(pal.soleCute, { rough: 0.55, coat: 0.3 }) : std(pal.sole, 0.6),
    sneaker: cute ? phys(pal.sneakerCute, { rough: 0.42, coat: 0.5, coatRough: 0.3 }) : std(pal.sneaker, 0.7),
    eye: new THREE.MeshBasicMaterial({ color: lin(pal.eye) }),
  };
  if (cat) {
    // Black fur with a violet sheen (the reference's rim-lit look), a deep
    // purple fleece hoodie, dark joggers; paws are fur (sneakers → fur).
    const fur = phys("#1d1424", { rough: 0.8, sheen: 1, sheenColor: "#b07ae6", sheenRough: 0.35 });
    const hoodie = { rough: 0.95, sheen: 0.9, sheenColor: "#b27ae8", sheenRough: 0.5 };
    Object.assign(mats, {
      skin: fur,
      shirt: phys("#221030", hoodie),
      shirtTails: phys("#221030", { ...hoodie, side: THREE.DoubleSide }),
      sleeve: phys("#221030", hoodie),
      collar: phys("#1c0c28", hoodie),
      jeans: phys("#1c1426", { rough: 0.92, sheen: 0.6, sheenColor: "#7a5a9a", sheenRough: 0.6 }),
      sneaker: fur,
      sole: fur,
    });
  }
  if (bee) {
    // Smooth, lightly lacquered cloth (the reference's soft-vinyl look), fair
    // skin, glossy black hair. Swapped before any mesh exists, like the hoodie.
    const honey = { rough: 0.45, coat: 0.4, coatRough: 0.3, sheen: 0.25, sheenColor: "#ffc060", sheenRough: 0.5 };
    const ink = { rough: 0.5, coat: 0.3, coatRough: 0.3 };
    Object.assign(mats, {
      skin: phys("#e8b294", { rough: 0.5, sheen: 0.35, sheenColor: "#ffd6c4", sheenRough: 0.6 }),
      hair: phys("#1b1515", { rough: 0.42, coat: 0.45, coatRough: 0.25 }),
      brow: std("#3b2419", 0.8),
      shirt: phys("#e07a08", honey),
      shirtTails: phys("#e07a08", { ...honey, side: THREE.DoubleSide }),
      sleeve: phys("#e07a08", honey),
      collar: phys("#1d191a", ink),
      jeans: phys("#1d191a", ink),
      phones: phys("#171314", { rough: 0.3, coat: 1, coatRough: 0.12 }),
      cushion: phys("#6b4632", { rough: 0.85, sheen: 0.5, sheenColor: "#a8795c" }),
      sneaker: phys("#e07a08", { rough: 0.42, coat: 0.5, coatRough: 0.3 }),
      sole: phys("#1d191a", { rough: 0.55, coat: 0.3 }),
    });
  }


  // Mouth meshes that open while Ledge speaks (rig.setTalk).
  const mouths = [];
  const root = new THREE.Group();
  const yaw = group(root);
  const pitch = group(yaw, 0, HIP_HEIGHT, 0);
  const hips = group(pitch);

  // Jeans seat (the untucked shirt hides the waistband).
  const pelvis = mesh(capsuleGeo(0.125, 0.125, 0.12), mats.jeans, 0, 0.0, 0);
  pelvis.rotation.z = Math.PI / 2;
  pelvis.scale.set(1, 1, 0.8);
  hips.add(pelvis);

  const spine = group(hips, 0, 0.06, 0);
  const torsoPts = TORSO.map(([r, y]) => V2(r, y));
  const shirt = mesh(new THREE.LatheGeometry(torsoPts, 28), mats.shirt, 0, 0, 0);
  shirt.scale.set(1.12, 1, 0.72);
  spine.add(shirt);

  // Button placket: small buttons sitting on the curve of the chest.
  const torsoR = (y) => {
    for (let i = 1; i < TORSO.length; i += 1) {
      const [r1, y1] = TORSO[i - 1];
      const [r2, y2] = TORSO[i];
      if (y <= y2) return r1 + ((r2 - r1) * (y - y1)) / (y2 - y1 || 1);
    }
    return 0;
  };
  const buttonGeo = new THREE.SphereGeometry(0.009, 8, 6);
  [0.43, 0.33, 0.23, 0.13, 0.03].forEach((y) =>
    spine.add(mesh(buttonGeo, mats.button, 0, y, torsoR(y) * 0.72 + 0.004))
  );

  // Collar: a band round the neck and two points spread over the collarbone.
  const band = mesh(new THREE.TorusGeometry(0.06, 0.015, 8, 22), mats.collar, 0, 0.53, 0.002);
  band.rotation.x = Math.PI / 2 - 0.12;
  band.scale.set(1.05, 0.9, 1);
  spine.add(band);
  // Each point is a small wedge lying on the chest, angled out and down
  // from the top button.
  const pointGeo = new THREE.BoxGeometry(0.07, 0.012, 0.06);
  [1, -1].forEach((s) => {
    const pt = mesh(pointGeo, mats.collar, s * 0.036, 0.515, 0.085);
    pt.rotation.set(-1.05, s * 0.2, s * 0.62);
    spine.add(pt);
  });

  // Untucked shirt hem on its own hinge so it can flutter.
  const tail = group(spine, 0, 0.02, 0);
  const tailPts = [V2(0.174, -0.12), V2(0.168, -0.06), V2(0.158, 0.0), V2(0.15, 0.03)];
  const tails = mesh(openShell(tailPts, 0.1), mats.shirtTails);
  tails.scale.set(1.12, 1, 0.84);
  tail.add(tails);

  const neck = group(spine, 0, 0.55, 0);
  neck.add(mesh(new THREE.CylinderGeometry(0.052, 0.06, 0.1, 14), mats.skin, 0, 0.02, 0));
  const head = group(neck, 0, 0.045, 0);

  // Face.
  const skull = mesh(new THREE.SphereGeometry(0.115, 28, 20), mats.skin, 0, 0.115, 0);
  skull.scale.set(0.88, 1.02, 0.98);
  head.add(skull);
  const jaw = mesh(new THREE.SphereGeometry(0.08, 20, 14), mats.skin, 0, 0.055, 0.028);
  jaw.scale.set(0.98, 0.8, 0.95);
  head.add(jaw);
  const earGeo = new THREE.SphereGeometry(0.028, 10, 8);
  [1, -1].forEach((s) => {
    const ear = mesh(earGeo, mats.skin, s * 0.1, 0.105, -0.008);
    ear.scale.set(0.45, 1, 0.75);
    head.add(ear);
  });
  const nose = mesh(new THREE.SphereGeometry(0.016, 10, 8), mats.skin, 0, 0.09, 0.107);
  nose.scale.set(0.9, 1.3, 0.9);
  head.add(nose);

  // Full short beard: the front of a shell hugging the jaw, from the cheek
  // line down, joined to the sideburns.
  const beard = mesh(
    new THREE.SphereGeometry(0.088, 24, 16, Math.PI / 2 - 1.75, 3.5, Math.PI * 0.4, Math.PI * 0.6),
    mats.beard,
    0,
    0.058,
    0.026
  );
  beard.scale.set(1.0, 0.86, 1.0);
  head.add(beard);
  // Moustache: two strokes meeting under the nose.
  const stacheGeo = capsuleGeo(0.008, 0.008, 0.022);
  [1, -1].forEach((s) => {
    const m = mesh(stacheGeo, mats.beard, s * 0.016, 0.071, 0.111);
    m.rotation.z = Math.PI / 2 + s * 0.28;
    head.add(m);
  });
  // A smile showing a sliver of teeth.
  const smile = mesh(
    new THREE.TorusGeometry(0.02, 0.0055, 6, 14, Math.PI),
    mats.teeth,
    0,
    0.062,
    0.113
  );
  smile.rotation.z = Math.PI;
  smile.scale.set(1, 0.55, 1);
  head.add(smile);

  const eyes = [];
  const eyeGeo = new THREE.SphereGeometry(0.0135, 10, 8);
  const browGeo = new THREE.BoxGeometry(0.046, 0.01, 0.012);
  [1, -1].forEach((s) => {
    const eye = mesh(eyeGeo, mats.eye, s * 0.038, 0.112, 0.1);
    eye.scale.set(1, 1.1, 0.6);
    head.add(eye);
    eyes.push(eye);
    const brow = mesh(browGeo, mats.brow, s * 0.039, 0.137, 0.102);
    // Outer ends dropped a touch: relaxed, not frowning.
    brow.rotation.z = s * -0.16;
    brow.rotation.y = s * 0.25;
    head.add(brow);
  });

  // Hair: tight sides and a lifted quiff swept up and back.
  const cap = mesh(
    new THREE.SphereGeometry(0.121, 28, 16, 0, Math.PI * 2, 0, Math.PI * 0.5),
    mats.hair,
    0,
    0.12,
    -0.008
  );
  // Tipped back so the hairline sits high on the forehead, low at the nape.
  cap.rotation.x = -0.5;
  cap.scale.set(0.92, 1.0, 1.01);
  head.add(cap);
  const back = mesh(new THREE.SphereGeometry(0.112, 20, 14), mats.hair, 0, 0.1, -0.03);
  back.scale.set(0.88, 0.95, 0.85);
  head.add(back);
  [1, -1].forEach((s) => {
    // Sideburns run down into the beard.
    const burn = mesh(new THREE.BoxGeometry(0.008, 0.06, 0.03), mats.beard, s * 0.093, 0.095, 0.03);
    head.add(burn);
  });
  const clumpGeo = new THREE.SphereGeometry(0.05, 12, 8);
  // [x, y, z, rotX, rotZ, scale]: the front row lifts highest, the rest lie
  // back over the crown.
  const CLUMPS = [
    [0.0, 0.228, 0.062, -1.0, 0.1, 1.05],
    [0.038, 0.222, 0.056, -0.95, 0.3, 0.95],
    [-0.038, 0.222, 0.052, -0.95, -0.15, 0.95],
    [0.012, 0.232, 0.018, -0.6, 0.2, 1.05],
    [-0.02, 0.228, -0.012, -0.35, 0.0, 1.0],
    [0.03, 0.222, -0.02, -0.35, 0.3, 0.95],
    [0.0, 0.212, -0.058, 0.1, 0.0, 0.95],
    [0.055, 0.205, 0.02, -0.4, 0.8, 0.75],
    [-0.055, 0.203, 0.018, -0.4, -0.8, 0.75],
  ];
  CLUMPS.forEach(([x, y, z, rx, rz, sc]) => {
    const c = mesh(clumpGeo, mats.hair, x, y, z);
    c.rotation.set(rx, 0, rz);
    c.scale.set(0.95 * sc, 0.5 * sc, 1.25 * sc);
    head.add(c);
  });

  // White over-ear headphones: a band over the quiff, cups on the ears.
  const phonesBand = mesh(
    new THREE.TorusGeometry(0.132, 0.011, 8, 32, Math.PI),
    mats.phones,
    0,
    0.118,
    -0.012
  );
  phonesBand.rotation.x = -0.18;
  phonesBand.scale.set(0.92, 1.02, 1);
  head.add(phonesBand);
  const cupGeo = new THREE.CylinderGeometry(0.043, 0.043, 0.032, 22);
  const padGeo = new THREE.TorusGeometry(0.036, 0.009, 8, 20);
  [1, -1].forEach((s) => {
    const cup = mesh(cupGeo, mats.phones, s * 0.116, 0.108, -0.01);
    cup.rotation.z = Math.PI / 2;
    head.add(cup);
    const pad = mesh(padGeo, mats.cushion, s * 0.1, 0.108, -0.01);
    pad.rotation.y = Math.PI / 2;
    head.add(pad);
  });

  // side +1 is the figure's left (+x when facing +z), -1 its right.
  const buildArm = (side) => {
    const sh = group(spine, side * 0.178, 0.445, 0);
    const delt = mesh(new THREE.SphereGeometry(0.06, 14, 10), mats.sleeve, side * -0.008, -0.01, 0);
    delt.scale.set(0.85, 0.95, 0.95);
    sh.add(delt);
    sh.add(mesh(capsuleGeo(0.052, 0.06, 0.17), mats.sleeve, 0, -0.14, 0));
    const el = group(sh, 0, -0.28, 0);
    el.add(mesh(new THREE.SphereGeometry(0.054, 12, 8), mats.sleeve, 0, -0.01, 0));
    // Full sleeve, pushed up a little so the wrist shows.
    el.add(mesh(capsuleGeo(0.044, 0.05, 0.12), mats.sleeve, 0, -0.09, 0));
    const cuff = mesh(new THREE.TorusGeometry(0.043, 0.01, 6, 16), mats.collar, 0, -0.17, 0);
    cuff.rotation.x = Math.PI / 2;
    cuff.scale.set(1, 1, 1.6);
    el.add(cuff);
    el.add(mesh(capsuleGeo(0.034, 0.04, 0.06), mats.skin, 0, -0.2, 0));
    const hand = group(el, 0, -0.265, 0);
    const palm = mesh(new THREE.SphereGeometry(0.046, 12, 10), mats.skin, 0, -0.01, 0);
    palm.scale.set(0.62, 1.15, 0.95);
    hand.add(palm);
    const thumb = mesh(capsuleGeo(0.014, 0.017, 0.035), mats.skin, 0, 0.0, 0.035);
    thumb.rotation.x = 0.5;
    hand.add(thumb);
    return { sh, el, hand };
  };

  const buildLeg = (side) => {
    const hip = group(hips, side * 0.095, -0.02, 0);
    // Thigh and shin overlap a rounded knee (like the elbow), so no gap
    // opens at the joint when the leg bends.
    hip.add(mesh(capsuleGeo(0.064, 0.086, 0.3), mats.jeans, 0, -0.228, 0));
    const knee = group(hip, 0, -0.45, 0);
    knee.add(mesh(new THREE.SphereGeometry(0.063, 14, 10), mats.jeans));
    knee.add(mesh(capsuleGeo(0.052, 0.063, 0.3), mats.jeans, 0, -0.205, 0));
    const cuff = mesh(new THREE.TorusGeometry(0.054, 0.014, 6, 16), mats.jeans, 0, -0.39, 0);
    cuff.rotation.x = Math.PI / 2;
    knee.add(cuff);
    const ankle = group(knee, 0, -0.43, 0);
    ankle.add(mesh(new THREE.SphereGeometry(0.047, 12, 8), mats.jeans, 0, 0.012, 0));
    // Sneaker: white sole, navy upper.
    const sole = mesh(capsuleGeo(0.048, 0.05, 0.13), mats.sole, 0, -0.055, 0.045);
    sole.rotation.x = Math.PI / 2;
    sole.scale.set(1.05, 1, 0.42);
    ankle.add(sole);
    const upper = mesh(capsuleGeo(0.042, 0.046, 0.1), mats.sneaker, 0, -0.03, 0.035);
    upper.rotation.x = Math.PI / 2;
    upper.scale.set(1, 1, 0.75);
    ankle.add(upper);
    ankle.add(mesh(new THREE.SphereGeometry(0.047, 10, 8), mats.sneaker, 0, -0.01, -0.01));
    return { hip, knee, ankle };
  };

  const rig = {
    root,
    yaw,
    pitch,
    hips,
    spine,
    tail,
    neck,
    eyes,
    arms: { L: buildArm(1), R: buildArm(-1) },
    legs: { L: buildLeg(1), R: buildLeg(-1) },
    mats,
  };

  if (cute) {
    // ── Chibi pass ─────────────────────────────────────────────────────────
    // A big head reads as friendly at a glance; the body keeps its proportions
    // so the tuned walk (and feet-on-ground maths) are untouched.
    // Chibi: the head is nearly as wide as the shoulders, and there's
    // hardly any neck (a long neck under a big head reads as a stick).
    head.scale.setScalar(1.85);
    head.position.y -= 0.035;
    neck.children[0].scale.y = 0.45;
    // Softer features: a smaller nose, a trimmed beard, the old eyes/smile off.
    nose.scale.set(0.6, 0.8, 0.6);
    // Clean-shaven (owner's call): no beard shell, moustache or sideburns.
    head.children.filter((c) => c.material === mats.beard).forEach((c) => (c.visible = false));
    // One round face: without the beard the separate jaw showed as a seam
    // (a pale band across the lower face). Chibi faces are a single shape.
    jaw.visible = false;
    skull.scale.set(0.93, 1.0, 1.0);
    smile.visible = false;
    eyes.forEach((e) => (e.visible = false));
    eyes.length = 0;

    const glossy = new THREE.MeshPhysicalMaterial({
      color: lin("#120c0a"), roughness: 0.35, metalness: 0, clearcoat: 0.6, clearcoatRoughness: 0.08,
      envMapIntensity: 0.35,
    });
    const white = new THREE.MeshBasicMaterial({ color: 0xffffff });
    const blush = new THREE.MeshBasicMaterial({ color: lin("#ff8fa3"), transparent: true, opacity: 0.45, depthWrite: false });
    const mouthMat = new THREE.MeshBasicMaterial({ color: lin("#5a2a26") });
    [1, -1].forEach((sd) => {
      // Big eyes, a little lower and wider apart than the realistic ones.
      const eye = new THREE.Group();
      // Just proud of the skull surface (z ≈ 0.107 at this x): any deeper and
      // the head swallows them into slits; much further and they bulge in profile.
      eye.position.set(sd * 0.041, 0.106, 0.0995);
      const ball = new THREE.Mesh(new THREE.SphereGeometry(0.025, 18, 14), glossy);
      ball.scale.set(0.9, 1.15, 0.42);
      eye.add(ball);
      // Two catchlights on the eye's front surface (flat discs just in front
      // of the flattened ball), both upper-left: one consistent key light.
      const front = 0.025 * 0.42 + 0.0006;
      const big = new THREE.Mesh(new THREE.CircleGeometry(0.0082, 18), white);
      big.position.set(-0.0065, 0.0095, front);
      eye.add(big);
      const small = new THREE.Mesh(new THREE.CircleGeometry(0.0038, 12), white);
      small.position.set(0.006, -0.009, front);
      eye.add(small);
      head.add(eye);
      eyes.push(eye);
      // Rosy cheeks.
      const cheek = new THREE.Mesh(new THREE.SphereGeometry(0.02, 14, 10), blush);
      cheek.position.set(sd * 0.064, 0.078, 0.086);
      cheek.scale.set(1.2, 0.55, 0.3);
      head.add(cheek);
    });
    // Brows: raised, thin, outer ends dropped — happy and curious. (Raising
    // the outer ends instead reads as a frown.)
    head.children
      .filter((c) => c.geometry && c.geometry.type === "BoxGeometry" && c.material === mats.brow)
      .forEach((b) => {
        b.position.y = 0.146;
        b.position.z -= 0.004;
        b.scale.set(0.78, 0.7, 1);
        b.rotation.z = Math.sign(b.position.x) * -0.26;
      });
    // No shirt buttons or collar points on a hoodie or the bee dress.
    spine.children
      .filter((c) => c.material === mats.button || (c.material === mats.collar && c.geometry.type === "BoxGeometry"))
      .forEach((c) => (c.visible = false));
    if (bee) {
      buildBee();
    } else {
    // The cat wears the hoodie with the hood UP (built in buildCat), yellow
    // strings and a zip instead of the badge.
    const hpal = cat ? { ...pal, string: "#f2c21b", hoodieDeep: "#221035" } : pal;
    // ── The Ledge hoodie ──────────────────────────────────────────────────
    // Hood, down: a thick roll behind the neck and a soft shell on the upper back.
    const hoodRoll = new THREE.Mesh(new THREE.TorusGeometry(0.085, 0.035, 12, 28), mats.collar);
    hoodRoll.position.set(0, 0.52, -0.02);
    hoodRoll.rotation.x = Math.PI / 2 - 0.35;
    hoodRoll.scale.set(1.25, 1.0, 1);
    if (!cat) spine.add(hoodRoll);
    const hoodBack = new THREE.Mesh(
      new THREE.SphereGeometry(0.13, 20, 14, 0, Math.PI * 2, 0, Math.PI * 0.5),
      mats.collar
    );
    hoodBack.position.set(0, 0.43, -0.075);
    hoodBack.rotation.x = -1.9;
    hoodBack.scale.set(1.05, 0.55, 0.9);
    if (!cat) spine.add(hoodBack);
    // Drawstrings with white aglets.
    const stringMat = cat ? phys(hpal.string, { rough: 0.35, coat: 0.6 }) : std(pal.string, 0.5);
    [1, -1].forEach((sd) => {
      const cord = new THREE.Mesh(capsuleGeo(0.0055, 0.0055, 0.13, 3), stringMat);
      cord.position.set(sd * 0.032, 0.445, 0.118);
      cord.rotation.x = -0.28;
      spine.add(cord);
      const tip = new THREE.Mesh(new THREE.SphereGeometry(0.009, 8, 6), stringMat);
      tip.position.set(sd * 0.032, 0.372, 0.137);
      spine.add(tip);
    });
    // Kangaroo pocket across the belly.
    const pocket = new THREE.Mesh(new THREE.BoxGeometry(0.2, 0.1, 0.02), std(hpal.hoodieDeep, 0.95));
    pocket.position.set(0, 0.085, torsoR(0.085) * 0.72 + 0.004);
    pocket.rotation.x = -0.05;
    spine.add(pocket);
    // A small glowing "L" badge on the chest.
    const badge = document.createElement("canvas");
    badge.width = 64;
    badge.height = 64;
    const bg = badge.getContext("2d");
    const grad = bg.createLinearGradient ? bg.createLinearGradient(0, 0, 64, 64) : null;
    if (grad) {
      grad.addColorStop(0, "#9fb8ff");
      grad.addColorStop(1, "#ff9ccf");
      bg.fillStyle = grad;
    } else bg.fillStyle = "#c9b8ff";
    if (bg.beginPath) {
      bg.beginPath();
      bg.arc(32, 32, 30, 0, Math.PI * 2);
      bg.fill();
      bg.fillStyle = "#ffffff";
      bg.font = "bold 40px -apple-system, Helvetica, Arial";
      bg.textAlign = "center";
      bg.textBaseline = "middle";
      bg.fillText("L", 32, 35);
    }
    const badgeTex = new THREE.CanvasTexture(badge);
    badgeTex.encoding = THREE.sRGBEncoding;
    textures.push(badgeTex);
    const badgeMesh = new THREE.Mesh(
      new THREE.CircleGeometry(0.03, 24),
      new THREE.MeshBasicMaterial({ map: badgeTex, transparent: true })
    );
    badgeMesh.position.set(0.075, 0.36, torsoR(0.36) * 0.72 + 0.006);
    badgeMesh.rotation.y = 0.28;
    if (!cat) spine.add(badgeMesh);
    // Ribbed hem: the shirt tails become a snug waistband (no flutter).
    tails.scale.set(1.08, 0.45, 0.8);

    // A happy "u" smile.
    const grin = new THREE.Mesh(new THREE.TorusGeometry(0.024, 0.0045, 8, 18, Math.PI), mouthMat);
    grin.position.set(0, 0.066, 0.106);
    grin.rotation.z = Math.PI;
    grin.scale.set(1, 0.7, 1);
    if (!cat) { head.add(grin); mouths.push(grin); }
    if (cat) buildCat(stringMat);
    }
  }

  // ── The cat (third avatar) ───────────────────────────────────────────────
  // After the reference: a round black cat face, hood up with pointed ears
  // through it, big green eyes behind yellow cat-eye glasses, a mauve nose,
  // whiskers, a yellow zip, and a tail that sways as she walks (rig.tick).
  function buildCat(yellowMat) {
    // Not human: no hair, headphones, human ears, brows, blush.
    head.children.forEach((c) => {
      const m = c.material;
      if (m === mats.hair || m === mats.phones || m === mats.cushion || m === mats.brow) c.visible = false;
      if (m && m.transparent && m.opacity === 0.45) c.visible = false; // blush
      if (c.geometry && c.geometry.type === "SphereGeometry" && c.geometry.parameters.radius === 0.028) c.visible = false;
    });
    // A rounder, wider cat head with full cheeks.
    skull.scale.set(1.06, 0.97, 1.0);
    [1, -1].forEach((sd) => {
      const cheek = new THREE.Mesh(new THREE.SphereGeometry(0.06, 18, 12), mats.skin);
      cheek.position.set(sd * 0.05, 0.07, 0.05);
      cheek.scale.set(1.1, 0.85, 0.9);
      head.add(cheek);
    });
    // Muzzle: two soft puffs under a small mauve nose, a little "w" mouth.
    [1, -1].forEach((sd) => {
      const puff = new THREE.Mesh(new THREE.SphereGeometry(0.017, 14, 10), mats.skin);
      puff.position.set(sd * 0.014, 0.07, 0.104);
      puff.scale.set(1.1, 0.85, 0.7);
      head.add(puff);
    });
    nose.material = phys("#8a4a78", { rough: 0.35, coat: 0.5, coatRough: 0.2 });
    nose.position.set(0, 0.083, 0.113);
    nose.scale.set(0.75, 0.45, 0.5);
    const mouthMat = new THREE.MeshBasicMaterial({ color: lin("#6e3b62") });
    [1, -1].forEach((sd) => {
      const arc = new THREE.Mesh(new THREE.TorusGeometry(0.008, 0.0016, 6, 12, Math.PI), mouthMat);
      arc.position.set(sd * 0.008, 0.066, 0.115);
      arc.rotation.z = Math.PI;
      head.add(arc);
      mouths.push(arc);
    });

    // Eyes: big and green, pale-green whites, dark round pupils.
    const irisTex = (() => {
      const c = document.createElement("canvas");
      c.width = 64;
      c.height = 64;
      const g = c.getContext("2d");
      const grad = g.createRadialGradient ? g.createRadialGradient(32, 36, 2, 32, 32, 31) : null;
      if (grad && g.beginPath) {
        grad.addColorStop(0, "#0b0a0c");
        grad.addColorStop(0.36, "#0b0a0c");
        grad.addColorStop(0.42, "#2f7d1c");
        grad.addColorStop(0.75, "#7fdc3a");
        grad.addColorStop(0.92, "#3b8c1e");
        grad.addColorStop(1, "#14330c");
        g.fillStyle = grad;
        g.beginPath();
        g.arc(32, 32, 31, 0, Math.PI * 2);
        g.fill();
      }
      const t = new THREE.CanvasTexture(c);
      t.encoding = THREE.sRGBEncoding;
      textures.push(t);
      return t;
    })();
    const irisMat = new THREE.MeshBasicMaterial({ map: irisTex, transparent: true });
    const front = 0.025 * 0.42 + 0.0003;
    eyes.forEach((eye) => {
      eye.position.y = 0.108;
      eye.position.x *= 1.12;
      eye.scale.set(1.12, 1.12, 1.12);
      eye.children[0].material = new THREE.MeshPhysicalMaterial({
        color: lin("#e4f2d6"), roughness: 0.3, clearcoat: 0.8, clearcoatRoughness: 0.06, envMapIntensity: 0.3,
      });
      const iris = new THREE.Mesh(new THREE.CircleGeometry(0.019, 28), irisMat);
      iris.position.set(0, -0.001, front);
      iris.scale.set(1, 1.1, 1);
      eye.add(iris);
      eye.children.slice(1, 3).forEach((c) => (c.position.z = front + 0.0006));
    });

    // Yellow cat-eye glasses: an extruded frame per eye with a green-tinted
    // lens, a bridge, and arms running back to the ears.
    const frameMat = phys("#f2c21b", { rough: 0.3, coat: 1, coatRough: 0.1 });
    const lensMat = new THREE.MeshPhysicalMaterial({
      color: lin("#7dff6a"), transparent: true, opacity: 0.22, roughness: 0.05, clearcoat: 1,
      depthWrite: false, side: THREE.DoubleSide,
    });
    const catEye = (r, lift) => {
      // A rounded lens shape with its outer-top corner swept up (the "cat eye").
      const sh = new THREE.Shape();
      sh.moveTo(-r, 0);
      sh.bezierCurveTo(-r, -0.75 * r, -0.35 * r, -r, 0.1 * r, -r);
      sh.bezierCurveTo(0.8 * r, -r, 1.15 * r, -0.4 * r, 1.2 * r, 0.25 * r);
      sh.bezierCurveTo(1.25 * r, 0.7 * r + lift, 1.3 * r, 0.95 * r + lift, 1.1 * r, 0.95 * r + lift);
      sh.bezierCurveTo(0.5 * r, 0.85 * r, -0.4 * r, 0.95 * r, -0.8 * r, 0.6 * r);
      sh.bezierCurveTo(-r, 0.45 * r, -r, 0.2 * r, -r, 0);
      return sh;
    };
    [1, -1].forEach((sd) => {
      const outer = catEye(0.036, 0.012);
      const hole = new THREE.Path(catEye(0.028, 0.006).getPoints(24));
      outer.holes.push(hole);
      const frame = new THREE.Mesh(
        new THREE.ExtrudeGeometry(outer, { depth: 0.004, bevelEnabled: true, bevelThickness: 0.002, bevelSize: 0.0015, bevelSegments: 2, curveSegments: 16 }),
        frameMat
      );
      frame.position.set(sd * 0.047, 0.106, 0.118);
      frame.scale.set(sd, 1, 1); // mirror so both swept corners point outward
      frame.rotation.y = sd * 0.12;
      head.add(frame);
      const lens = new THREE.Mesh(new THREE.ShapeGeometry(catEye(0.029, 0.007), 16), lensMat);
      lens.position.set(sd * 0.047, 0.106, 0.12);
      lens.scale.set(sd, 1, 1);
      lens.rotation.y = sd * 0.12;
      head.add(lens);
      const arm = new THREE.Mesh(new THREE.BoxGeometry(0.004, 0.006, 0.11), frameMat);
      arm.position.set(sd * 0.098, 0.115, 0.065);
      arm.rotation.y = sd * -0.12;
      head.add(arm);
    });
    const bridge = new THREE.Mesh(capsuleGeo(0.003, 0.003, 0.02, 3), frameMat);
    bridge.position.set(0, 0.107, 0.122);
    bridge.rotation.z = Math.PI / 2;
    head.add(bridge);

    // Whiskers: three fine strands each side, fanning out from the muzzle.
    const whiskerMat = new THREE.MeshBasicMaterial({ color: lin("#d9d0e2"), transparent: true, opacity: 0.8 });
    [1, -1].forEach((sd) => {
      [-0.12, 0.0, 0.12].forEach((a, i) => {
        const w = new THREE.Mesh(new THREE.CylinderGeometry(0.0007, 0.0012, 0.09, 4), whiskerMat);
        w.position.set(sd * 0.068, 0.07 + i * 0.006 - 0.006, 0.098);
        w.rotation.z = sd * (Math.PI / 2 + a);
        w.rotation.y = sd * -0.35;
        head.add(w);
      });
    });

    // Hood up: an open-fronted shell around the head, a rolled rim framing the
    // face, and pointed ears poking through (fur outside, mauve inside).
    // The shell is a sphere with a round hole cut around its pole, turned so
    // the hole faces forward (a phi-gap left a slit over the crown).
    const OPEN = 0.82; // half-angle of the face opening
    const hoodShell = new THREE.Mesh(
      new THREE.SphereGeometry(0.128, 32, 22, 0, Math.PI * 2, OPEN, Math.PI - OPEN),
      mats.collar
    );
    hoodShell.rotation.x = Math.PI / 2;
    hoodShell.position.set(0, 0.108, -0.012);
    hoodShell.scale.set(1.12, 1.05, 1.1);
    head.add(hoodShell);
    // A soft rolled edge right at the opening, hugging the face.
    const rim = new THREE.Mesh(new THREE.TorusGeometry(0.128 * Math.sin(OPEN), 0.013, 12, 40), mats.collar);
    rim.position.set(0, 0.108, -0.012 + 0.128 * 1.1 * Math.cos(OPEN));
    rim.scale.set(1.12, 1.05, 1);
    head.add(rim);
    const inner = phys("#8a4a78", { rough: 0.8, sheen: 0.6, sheenColor: "#e0a0d0" });
    [1, -1].forEach((sd) => {
      const ear = new THREE.Mesh(new THREE.ConeGeometry(0.045, 0.11, 18), mats.skin);
      ear.position.set(sd * 0.08, 0.262, -0.015);
      ear.rotation.z = sd * -0.38;
      ear.scale.set(1, 1, 0.55);
      head.add(ear);
      const earIn = new THREE.Mesh(new THREE.ConeGeometry(0.03, 0.08, 16), inner);
      earIn.position.set(sd * 0.077, 0.257, 0.001);
      earIn.rotation.z = sd * -0.38;
      earIn.scale.set(1, 1, 0.3);
      head.add(earIn);
    });

    // Yellow zip down the front, with a pull.
    const zip = new THREE.Mesh(new THREE.BoxGeometry(0.012, 0.44, 0.006), yellowMat);
    zip.position.set(0, 0.25, torsoR(0.25) * 0.72 + 0.004);
    spine.add(zip);
    const pull = new THREE.Mesh(new THREE.BoxGeometry(0.014, 0.03, 0.005), yellowMat);
    pull.position.set(0, 0.43, torsoR(0.43) * 0.72 + 0.012);
    pull.rotation.x = -0.3;
    spine.add(pull);

    // Tail: a curved fur tube from the seat, swaying side to side.
    const tailPivot = new THREE.Group();
    tailPivot.position.set(0, 0.0, -0.1);
    tailPivot.userData.tail = true;
    const curve = new THREE.CatmullRomCurve3([
      new THREE.Vector3(0, 0, 0),
      new THREE.Vector3(0, -0.06, -0.12),
      new THREE.Vector3(0.02, 0.05, -0.24),
      new THREE.Vector3(0.05, 0.2, -0.27),
      new THREE.Vector3(0.08, 0.3, -0.22),
    ]);
    tailPivot.add(new THREE.Mesh(new THREE.TubeGeometry(curve, 40, 0.024, 12, false), mats.skin));
    const tip = new THREE.Mesh(new THREE.SphereGeometry(0.024, 12, 10), mats.skin);
    tip.position.copy(curve.getPoint(1));
    tailPivot.add(tip);
    hips.add(tailPivot);
    let tt = 0;
    rig.tick = (dt, lively = 0) => {
      tt += dt * (1.6 + 2.2 * lively);
      tailPivot.rotation.y = 0.45 * Math.sin(tt);
      tailPivot.rotation.z = 0.12 * Math.sin(tt * 0.5 + 1);
    };
    rig.tick(0);
  }

  // ── The bee (second avatar) ──────────────────────────────────────────────
  // Built on the chibi pass above (big head, clean face, eye groups), then
  // restyled after the reference: bob with centre-parted bangs under an orange
  // cap with bobbled antennae, black/orange headphones, amber eyes with
  // lashes, an orange dress with puffed sleeves over black, five heart
  // buttons, and translucent veined wings that flutter (rig.tick).
  function buildBee() {
    // Hair: the quiff clumps go; the cap and back stay as the bob's crown.
    head.children
      .filter((c) => c.material === mats.hair && c.geometry.type === "SphereGeometry" && c.geometry.parameters.radius === 0.05)
      .forEach((c) => (c.visible = false));
    const lock = (x, y, z, sx, sy, sz, rz, r = 0.05) => {
      const m = new THREE.Mesh(new THREE.SphereGeometry(r, 18, 12), mats.hair);
      m.position.set(x, y, z);
      m.scale.set(sx, sy, sz);
      m.rotation.z = rz;
      head.add(m);
      return m;
    };
    [1, -1].forEach((sd) => {
      // Centre-parted blunt fringe: a smooth shell over the forehead on each side
      // of the parting. (Tried: separate locks read as horns, strand tips as
      // curls, curtain locks as angry brows — the clean shell reads best.)
      const fringe = new THREE.Mesh(
        new THREE.SphereGeometry(0.124, 28, 12, Math.PI / 2 + (sd > 0 ? -1.3 : 0.05), 1.25, 0.28, 0.9),
        mats.hair
      );
      fringe.position.set(0, 0.113, 0.0);
      fringe.rotation.z = sd * -0.08;
      fringe.scale.set(0.97, 1.0, 1.0);
      head.add(fringe);
      // Bob falling past the ears to the jaw, with a curl at the ends.
      lock(sd * 0.093, 0.085, -0.004, 0.5, 1.3, 0.95, sd * -0.08, 0.06);
      lock(sd * 0.086, 0.03, 0.012, 0.5, 0.42, 0.62, sd * 0.5, 0.045);
    });
    lock(0, 0.075, -0.05, 2.0, 1.55, 1.45, 0, 0.06);

    // Cap: an orange dome over the crown with a dark seam over the top.
    const honey = mats.shirt;
    const hat = new THREE.Mesh(new THREE.SphereGeometry(0.122, 30, 16, 0, Math.PI * 2, 0, Math.PI * 0.4), honey);
    hat.position.set(0, 0.128, -0.012);
    hat.rotation.x = -0.32;
    hat.scale.set(0.96, 1, 1.02);
    head.add(hat);
    // Antennae: thin black stalks curving out, each ending in an orange bobble
    // with a dark tip.
    const stalk = mats.phones;
    [1, -1].forEach((sd) => {
      const curve = new THREE.CatmullRomCurve3([
        new THREE.Vector3(sd * 0.03, 0.235, 0.0),
        new THREE.Vector3(sd * 0.05, 0.285, 0.012),
        new THREE.Vector3(sd * 0.085, 0.32, 0.02),
        new THREE.Vector3(sd * 0.115, 0.335, 0.022),
      ]);
      head.add(new THREE.Mesh(new THREE.TubeGeometry(curve, 16, 0.0035, 6, false), stalk));
      const bob = new THREE.Mesh(new THREE.SphereGeometry(0.02, 18, 12), honey);
      bob.position.set(sd * 0.125, 0.338, 0.022);
      head.add(bob);
      const dot = new THREE.Mesh(new THREE.SphereGeometry(0.0065, 10, 8), stalk);
      dot.position.set(sd * 0.139, 0.33, 0.028);
      head.add(dot);
    });
    // Headphones: black band and cups (from the materials), orange cup faces.
    [1, -1].forEach((sd) => {
      const face = new THREE.Mesh(new THREE.CylinderGeometry(0.03, 0.03, 0.006, 22), honey);
      face.position.set(sd * 0.134, 0.108, -0.01);
      face.rotation.z = Math.PI / 2;
      head.add(face);
    });

    // Face: amber irises with a dark ring and pupil over a white, lashes,
    // softer brows, a small rosy smile.
    const irisTex = (() => {
      const c = document.createElement("canvas");
      c.width = 64;
      c.height = 64;
      const g = c.getContext("2d");
      const grad = g.createRadialGradient ? g.createRadialGradient(32, 38, 2, 32, 32, 31) : null;
      if (grad && g.beginPath) {
        grad.addColorStop(0, "#1a0d05");
        grad.addColorStop(0.3, "#1a0d05");
        grad.addColorStop(0.36, "#c4600e");
        grad.addColorStop(0.7, "#f59a2a");
        grad.addColorStop(0.9, "#9a4a0a");
        grad.addColorStop(1, "#3a1a06");
        g.fillStyle = grad;
        g.beginPath();
        g.arc(32, 32, 31, 0, Math.PI * 2);
        g.fill();
      }
      const t = new THREE.CanvasTexture(c);
      t.encoding = THREE.sRGBEncoding;
      textures.push(t);
      return t;
    })();
    const irisMat = new THREE.MeshBasicMaterial({ map: irisTex, transparent: true });
    const lashMat = new THREE.MeshBasicMaterial({ color: lin("#140e0d") });
    eyes.forEach((eye) => {
      const sd = Math.sign(eye.position.x);
      eye.position.y = 0.104;
      const ball = eye.children[0];
      ball.material = new THREE.MeshPhysicalMaterial({
        color: lin("#f6f1ee"), roughness: 0.3, clearcoat: 0.8, clearcoatRoughness: 0.06, envMapIntensity: 0.3,
      });
      const front = 0.025 * 0.42 + 0.0003;
      const iris = new THREE.Mesh(new THREE.CircleGeometry(0.0185, 28), irisMat);
      iris.position.set(0, -0.002, front);
      iris.scale.set(0.95, 1.12, 1);
      eye.add(iris);
      // Catchlights sit in front of the iris.
      eye.children.slice(1, 3).forEach((c) => (c.position.z = front + 0.0006));
      // Upper lash line hugging the top of the eye, flicked out at the corner.
      const lid = new THREE.Mesh(new THREE.TorusGeometry(0.0232, 0.0026, 6, 20, Math.PI), lashMat);
      lid.position.set(0, 0.001, front + 0.001);
      lid.scale.set(0.95, 1.2, 1);
      eye.add(lid);
      const flick = new THREE.Mesh(capsuleGeo(0.0018, 0.0026, 0.012, 3), lashMat);
      flick.position.set(sd * 0.024, 0.014, front + 0.001);
      flick.rotation.z = sd * -0.9;
      eye.add(flick);
    });
    head.children
      .filter((c) => c.material === mats.brow)
      .forEach((b) => {
        b.position.y = 0.143;
        b.scale.set(0.72, 0.55, 1);
        b.rotation.z = Math.sign(b.position.x) * -0.12;
      });
    head.children
      .filter((c) => c.material && c.material.transparent && c.material.opacity === 0.45)
      .forEach((c) => {
        c.material = c.material.clone();
        c.material.opacity = 0.32;
        c.position.y = 0.074;
      });
    const lips = new THREE.Mesh(
      new THREE.TorusGeometry(0.014, 0.0038, 8, 16, Math.PI),
      new THREE.MeshPhysicalMaterial({ color: lin("#d9707a"), roughness: 0.35, clearcoat: 0.6 })
    );
    lips.position.set(0, 0.066, 0.106);
    lips.rotation.z = Math.PI;
    lips.scale.set(1, 0.55, 1);
    head.add(lips);
    mouths.push(lips);

    // Dress: black striped turtleneck under an orange bodice, flared skirt.
    const neckMesh = neck.children[0];
    neckMesh.material = mats.collar;
    tails.scale.set(1.24, 0.85, 1.08);
    // Puffed sleeves over black arms.
    Object.values(rig.arms).forEach(({ sh, el }) => {
      const [delt, upper] = sh.children;
      delt.scale.set(1.45, 1.35, 1.45);
      delt.position.y = -0.03;
      upper.material = mats.collar;
      el.children.slice(0, 3).forEach((c) => (c.material = mats.collar));
    });
    // Five little black hearts, three over two.
    const heartShape = new THREE.Shape();
    heartShape.moveTo(0, -0.5);
    heartShape.bezierCurveTo(-0.15, -0.3, -0.55, -0.05, -0.5, 0.2);
    heartShape.bezierCurveTo(-0.45, 0.48, -0.1, 0.52, 0, 0.25);
    heartShape.bezierCurveTo(0.1, 0.52, 0.45, 0.48, 0.5, 0.2);
    heartShape.bezierCurveTo(0.55, -0.05, 0.15, -0.3, 0, -0.5);
    const heartGeo = new THREE.ExtrudeGeometry(heartShape, {
      depth: 0.15, bevelEnabled: true, bevelThickness: 0.12, bevelSize: 0.08, bevelSegments: 3, curveSegments: 10,
    });
    const heartMat = new THREE.MeshStandardMaterial({ color: lin("#0e0a0a"), roughness: 0.55, envMapIntensity: 0.15 });
    [[-0.045, 0.35], [0, 0.355], [0.045, 0.35], [-0.023, 0.295], [0.023, 0.295]].forEach(([x, y]) => {
      const h = new THREE.Mesh(heartGeo, heartMat);
      h.scale.setScalar(0.038);
      h.position.set(x, y, torsoR(y) * 0.72 + 0.002);
      h.rotation.x = -0.1;
      spine.add(h);
    });

    // Wings: veined, amber-tinted glass on a hinge between the shoulders.
    const wingTex = (() => {
      const c = document.createElement("canvas");
      c.width = 128;
      c.height = 192;
      const g = c.getContext("2d");
      if (g.beginPath && g.ellipse) {
        g.fillStyle = "rgba(255, 190, 110, 0.55)";
        g.beginPath();
        g.ellipse(64, 96, 60, 92, 0, 0, Math.PI * 2);
        g.fill();
        g.strokeStyle = "rgba(236, 142, 40, 0.95)";
        g.lineWidth = 3;
        g.stroke();
        g.lineWidth = 2;
        g.strokeStyle = "rgba(236, 142, 40, 0.75)";
        [[64, 188, 64, 8], [64, 150, 18, 60], [64, 150, 110, 60], [64, 110, 14, 120], [64, 110, 114, 120],
         [64, 70, 30, 20], [64, 70, 98, 20]].forEach(([x1, y1, x2, y2]) => {
          g.beginPath();
          g.moveTo(x1, y1);
          g.quadraticCurveTo((x1 + x2) / 2 + (x2 - x1) * 0.1, (y1 + y2) / 2, x2, y2);
          g.stroke();
        });
      }
      const t = new THREE.CanvasTexture(c);
      t.encoding = THREE.sRGBEncoding;
      textures.push(t);
      return t;
    })();
    const wingMat = new THREE.MeshPhysicalMaterial({
      map: wingTex, transparent: true, side: THREE.DoubleSide, depthWrite: false,
      roughness: 0.15, clearcoat: 1, clearcoatRoughness: 0.05, envMapIntensity: 0.6,
    });
    const wings = [];
    [1, -1].forEach((sd) => {
      const hinge = new THREE.Group();
      hinge.position.set(sd * 0.05, 0.4, -0.11);
      // [width, height, x, y, tilt]: a big upper wing, a smaller lower one.
      [[0.2, 0.34, 0.1, 0.1, 0.55], [0.14, 0.22, 0.075, -0.07, 1.9]].forEach(([w, h, x, y, tilt]) => {
        const wing = new THREE.Mesh(new THREE.PlaneGeometry(w, h), wingMat);
        wing.position.set(sd * x, y, 0);
        wing.rotation.z = sd * -tilt;
        hinge.add(wing);
      });
      hinge.userData.side = sd;
      spine.add(hinge);
      wings.push(hinge);
    });
    let wt = 0;
    // A slow, shimmering flutter — she walks; the wings are for charm.
    rig.tick = (dt, lively = 0) => {
      wt += dt * (2.2 + 4 * lively);
      wings.forEach((w) => {
        const sd = w.userData.side;
        w.rotation.y = sd * (0.55 + 0.16 * Math.sin(wt) + 0.05 * Math.sin(wt * 2.7));
      });
    };
    rig.tick(0);
  }

  mouths.forEach((m) => (m.userData.sy = m.scale.y));
  rig.setTalk = (v) => mouths.forEach((m) => (m.scale.y = m.userData.sy * (1 + 2.6 * v)));
  rig.setBlink = (v) => eyes.forEach((e) => (e.scale.y = (cute ? 1 : 1.1) * (1 - 0.88 * v)));

  rig.dispose = () => {
    root.traverse((o) => o.geometry && o.geometry.dispose());
    Object.values(mats).forEach((m) => m.dispose());
    textures.forEach((t) => t.dispose());
  };

  return rig;
};

const SIDES = [
  ["L", 1],
  ["R", -1],
];

export const applyPose = (rig, P) => {
  rig.pitch.rotation.x = P.pitch;
  rig.hips.position.y = P.hipsY;
  rig.hips.rotation.y = P.hipsYaw;
  rig.spine.rotation.x = P.lean;
  rig.spine.rotation.y = P.twist;
  rig.tail.rotation.x = P.tail;
  rig.neck.rotation.x = P.neckX;
  rig.neck.rotation.y = P.neckY - P.twist * 0.8;
  for (const [k, s] of SIDES) {
    const a = rig.arms[k];
    a.sh.rotation.set(P[`shX${k}`], s * P[`shY${k}`], s * P[`shZ${k}`]);
    a.el.rotation.x = -P[`el${k}`];
    const l = rig.legs[k];
    l.hip.rotation.x = P[`th${k}`];
    l.knee.rotation.x = P[`kn${k}`];
    l.ankle.rotation.x = P[`an${k}`];
  }
};

// out[k] = a[k] blended toward b[k], only over the joints b defines, so a
// partial pose (legs only, arms only) overlays a full one.
export const mixInto = (a, b, w) => {
  if (w <= 0.0001) return a;
  for (const k in b) a[k] += (b[k] - a[k]) * w;
  return a;
};

/* ------------------------------------------------------------------ */
/* Poses                                                               */
/* ------------------------------------------------------------------ */

// Standing, walking and running are one pose driven by speed: amp 0 is
// standing still, amp 1 a full stride, run 0..1 stretches it into a sprint.
export const groundPose = ({ phase, amp, run, t, lookY }) => {
  const sway = Math.sin(t * 1.7);
  const still = 1 - amp;
  const P = {
    pitch: 0,
    lean: 0.03 * still + 0.012 * sway * still + amp * (0.06 + 0.24 * run),
    hipsY:
      amp * (0.018 + 0.05 * run) * (Math.abs(Math.cos(phase)) - 0.6) +
      still * 0.004 * sway,
    neckX: 0,
    neckY: lookY,
    // Shoulders counter-rotate against the hips, as in a real stride.
    hipsYaw: -0.07 * amp * Math.sin(phase),
    twist: 0.15 * amp * Math.sin(phase),
    tail: amp * (0.08 + 0.3 * run) + 0.04 * amp * Math.sin(phase * 2),
  };
  P.neckX = -P.lean * 0.6 + still * 0.03 * Math.sin(t * 0.9);
  for (const [k] of SIDES) {
    const p = phase + (k === "L" ? 0 : Math.PI);
    const sw = Math.sin(p);
    const swing = Math.max(0, Math.cos(p));
    P[`th${k}`] = -(0.42 + 0.3 * run) * amp * sw;
    P[`kn${k}`] =
      0.05 + amp * (0.1 + 0.25 * run + (0.6 + 0.85 * run) * Math.pow(swing, 1.4));
    P[`an${k}`] = amp * (0.12 * sw + 0.25 * run * swing);
    P[`shX${k}`] = (0.3 + 0.45 * run) * amp * sw;
    P[`shY${k}`] = 0;
    P[`shZ${k}`] = 0.08 + 0.05 * run + still * 0.012 * sway;
    P[`el${k}`] = 0.18 + amp * (0.15 + 1.05 * run);
  }
  return P;
};

// Flight body, in the body's own frame (Dreamer.js aligns the whole body to
// the flight path). `turn` > 0 when curving toward his back (pulling up):
// he arches into it, head up, legs swinging wide; < 0 he tucks. `pitch` here
// is only the upright lean used while hovering.
export const flyBody = ({ t, climb, turn = 0, speed = 150, hoverVx = 0 }) => {
  const fast = Math.min(1, speed / 300);
  const P = {
    pitch: 0.12 + Math.max(-0.2, Math.min(0.35, hoverVx / 500)),
    lean: -0.1 - 0.16 * turn,
    hipsY: 0,
    neckX: -0.95 + 0.15 * climb - 0.22 * turn,
    neckY: 0,
    hipsYaw: 0,
    twist: 0.04 * Math.sin(t * 0.9),
    // Shirt tails stream harder and flutter faster with speed.
    tail:
      0.18 +
      0.18 * fast +
      (0.05 + 0.05 * fast) * Math.sin(t * (8 + 10 * fast)) +
      0.03 * Math.sin(t * 17),
  };
  for (const [k, s] of SIDES) {
    const kick = Math.sin(t * 1.4 + s * 1.3) * (1 - 0.6 * fast);
    // Legs trail: straighter and closer together at speed, swinging out
    // behind the arc of a turn.
    P[`th${k}`] = 0.1 + 0.06 * kick + 0.14 * turn;
    P[`kn${k}`] = 0.12 + (0.3 + 0.18 * kick) * (1 - 0.55 * fast) - 0.1 * turn;
    P[`an${k}`] = 0.55 + 0.25 * fast;
  }
  return P;
};

// Full-speed "dash": left fist punched forward past the head, right arm
// swept back along the body.
export const dashArms = () => ({
  shXL: -2.95,
  shYL: 0,
  shZL: 0.16,
  elL: 0.06,
  shXR: 0.3,
  shYR: 0,
  shZR: 0.14,
  elR: 0.12,
});

// Carrying Mochi: both arms reach forward and bend in, cradling her under his
// chest (in flight, "forward" of the shoulders is toward the ground).
export const carryArms = () => ({
  shXL: -1.2,
  shYL: 0,
  shZL: 0.3,
  elL: 1.05,
  shXR: -1.2,
  shYR: 0,
  shZR: 0.3,
  elR: 1.05,
});

// Landing flare: stand up, legs reach forward for the ground.
export const flarePose = () => {
  const P = { pitch: -0.12, lean: -0.1, neckX: 0.15, tail: 0.35 };
  for (const [k, s] of SIDES) {
    P[`th${k}`] = -0.7 + s * 0.08;
    P[`kn${k}`] = 0.75;
    P[`an${k}`] = -0.15;
  }
  return P;
};

// Arms as wings. `f` is the stroke (-1 down .. 1 up), `A` its amplitude,
// `p` how horizontal the body is (0 upright, 1 flat). Upright, a wingbeat is
// abduction (raising the arms sideways); lying flat, the same world-up motion
// is a sweep around the spine, so the stroke is split between the two axes.
export const flapArms = ({ f, A, p, upstroke }) => {
  const raise = A * f + 0.12;
  const P = {};
  for (const [k] of SIDES) {
    P[`shZ${k}`] = 1.3 + raise * (1 - p);
    P[`shY${k}`] = raise * p;
    P[`shX${k}`] = -0.12 * (1 - p);
    P[`el${k}`] = 0.12 + 0.45 * upstroke;
  }
  return P;
};

// ── Desktop Ledge gestures (partial poses, blended like the rest) ──────────

// A friendly wave: right arm up beside the head, swinging side to side from
// the shoulder, elbow soft. `t` drives the swing.
export const wavePose = ({ t }) => ({
  shXR: -0.25,
  shYR: 0.15,
  shZR: 2.55 + 0.28 * Math.sin(t * 9),
  elR: 0.75 + 0.15 * Math.sin(t * 9 + 0.8),
  shXL: 0.08,
  shZL: 0.12,
  elL: 0.2,
  neckY: 0,
});

// Picked up: arms reach up (as if lifted by the hood), legs kick lazily.
export const danglePose = ({ t }) => ({
  // Held by the hood: arms up to the hood, legs hanging loose with a slow,
  // small, human kick (not a cartoon pedal).
  shXL: -2.75, shZL: 0.25, elL: 0.25, shXR: -2.75, shZR: 0.25, elR: 0.25,
  thL: -0.12 + 0.12 * Math.sin(t * 2.1), thR: -0.12 - 0.12 * Math.sin(t * 2.1),
  knL: 0.25 + 0.1 * Math.sin(t * 2.1 + 1), knR: 0.25 - 0.1 * Math.sin(t * 2.1 + 1),
  anL: 0.35, anR: 0.35, lean: 0.05,
});

// Dancing while music plays. `b` is the beat phase (2π per beat). Three moves
// share a knee-bounce + head-nod groove and are blended by weight `w`
// ([bob, pump, sway]) so switching moves never snaps:
//   bob  — fists up, elbows pumping back and forth
//   pump — one fist pumping the air, the other on the hip (alternates)
//   sway — arms loose and out, hips and shoulders swaying on the half-beat
export const dancePose = ({ b, w, pumpSide = 1 }) => {
  const bounce = 0.5 - 0.5 * Math.cos(b); // 0 on the beat's up, 1 down
  const half = Math.sin(b / 2);
  const P = {
    hipsY: -0.028 * bounce,
    lean: 0.05 + 0.04 * bounce,
    neckX: 0.16 * bounce - 0.05,
    neckY: 0.12 * half * w[2],
    hipsYaw: 0.22 * half * w[2],
    twist: -0.2 * half * w[2] + 0.06 * half * w[0],
    tail: 0.08 * bounce,
  };
  for (const [k, s] of SIDES) {
    P[`th${k}`] = -0.14 * bounce;
    P[`kn${k}`] = 0.18 + 0.3 * bounce;
    P[`an${k}`] = 0.12 * bounce;
    // bob: forearms up, elbows swinging opposite each other
    const bobX = -0.35 + 0.4 * s * half;
    // pump: pumping side reaches up on every beat, the other rests on the hip
    const up = s === pumpSide;
    const pumpX = up ? -0.35 : 0.15;
    const pumpZ = up ? 2.5 - 0.35 * bounce : 0.75;
    const pumpEl = up ? 0.25 + 0.7 * bounce : 1.5;
    // sway: arms out, rising and falling with the hips
    const swayZ = 0.85 + 0.35 * s * half;
    P[`shX${k}`] = w[0] * bobX + w[1] * pumpX + w[2] * -0.1;
    P[`shY${k}`] = 0;
    P[`shZ${k}`] = w[0] * (0.35 + 0.08 * bounce) + w[1] * pumpZ + w[2] * swayZ;
    P[`el${k}`] = w[0] * (1.45 - 0.25 * bounce) + w[1] * pumpEl + w[2] * (0.35 + 0.15 * bounce);
  }
  return P;
};

// "Done ✓": arms thrown up in a V with a little wiggle, two small hops at the
// start. `k` = seconds since it began.
export const celebratePose = ({ t, k }) => {
  const hop = k < 1.2 ? Math.max(0, Math.sin(k * Math.PI * 2 * 0.85)) : 0;
  const crouch = k < 1.2 ? Math.max(0, -Math.sin(k * Math.PI * 2 * 0.85)) : 0;
  const P = {
    hipsY: 0.09 * hop - 0.03 * crouch,
    lean: -0.06,
    neckX: -0.22,
    tail: 0.2 * hop,
  };
  for (const [k2, s] of SIDES) {
    P[`shX${k2}`] = -0.25;
    P[`shY${k2}`] = 0;
    P[`shZ${k2}`] = 2.45 + 0.15 * Math.sin(t * 11 + s);
    P[`el${k2}`] = 0.25 + 0.2 * Math.sin(t * 11 + s * 2);
    P[`th${k2}`] = -0.25 * crouch;
    P[`kn${k2}`] = 0.1 + 0.55 * crouch + 0.15 * hop;
    P[`an${k2}`] = 0.2 * crouch - 0.25 * hop;
  }
  return P;
};

// "Need your OK": right arm points up toward the notch (with a small insistent
// bob), left hand on the hip, chin up.
export const pointPose = ({ t }) => ({
  shXR: -2.35 + 0.08 * Math.sin(t * 5),
  shYR: 0,
  shZR: 0.55,
  elR: 0.12,
  shXL: 0.15,
  shYL: 0,
  shZL: 0.75,
  elL: 1.5,
  neckX: -0.38,
  lean: -0.04,
});

// Dozing: head drooped, shoulders slumped, arms hanging, slow deep breaths.
export const sleepPose = ({ t }) => {
  const breath = Math.sin(t * 1.25);
  const P = {
    neckX: 0.58 + 0.04 * breath,
    neckY: 0.12,
    lean: 0.14 + 0.02 * breath,
    hipsY: -0.012 + 0.006 * breath,
    twist: 0,
    tail: 0,
  };
  for (const [k] of SIDES) {
    P[`shX${k}`] = 0.12;
    P[`shY${k}`] = 0;
    P[`shZ${k}`] = 0.06 + 0.02 * breath;
    P[`el${k}`] = 0.35;
    P[`th${k}`] = -0.08;
    P[`kn${k}`] = 0.22;
    P[`an${k}`] = 0.1;
  }
  return P;
};
