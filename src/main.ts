import * as THREE from "three";

// ---------------------------------------------------------------------------
// Bonnezeaux — first prototype: sail a little boat around some islands.
// Low-poly + a PS1 vibe (low internal resolution upscaled with nearest filter,
// flat shading, chunky water). Replace/extend freely.
// ---------------------------------------------------------------------------

const app = document.getElementById("app")!;

const renderer = new THREE.WebGLRenderer({ antialias: false });
renderer.setPixelRatio(1); // PS1 look comes from rendering low-res, not crisp
app.appendChild(renderer.domElement);

// The scene is rendered into this low-res target, then blitted to the screen
// with NearestFilter — the classic chunky PlayStation-1 pixelation.
const RES_SCALE = 0.4;
let rt = new THREE.WebGLRenderTarget(1, 1, {
  minFilter: THREE.NearestFilter,
  magFilter: THREE.NearestFilter,
});

const scene = new THREE.Scene();
const SKY = new THREE.Color(0x9fd3e8);
scene.background = SKY;
scene.fog = new THREE.Fog(SKY, 80, 230);

// Isometric-ish camera: orthographic, looking down at a fixed angle.
const VIEW = 60; // world units visible vertically; smaller = more zoomed in
const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.1, 1000);

// Fullscreen pass that draws the low-res target to the canvas.
const screenScene = new THREE.Scene();
const screenCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
const screenQuad = new THREE.Mesh(
  new THREE.PlaneGeometry(2, 2),
  new THREE.MeshBasicMaterial({ map: rt.texture })
);
screenScene.add(screenQuad);

// --- Lighting -------------------------------------------------------------
scene.add(new THREE.HemisphereLight(0xcfeaff, 0x335577, 1.0));
const sun = new THREE.DirectionalLight(0xfff2d8, 1.4);
sun.position.set(40, 60, 20);
scene.add(sun);

// --- Water ----------------------------------------------------------------
const WATER_SIZE = 600;
const waterGeo = new THREE.PlaneGeometry(WATER_SIZE, WATER_SIZE, 80, 80);
waterGeo.rotateX(-Math.PI / 2);
const waterMat = new THREE.MeshStandardMaterial({
  color: 0x2f7fb5,
  flatShading: true,
  roughness: 0.6,
  metalness: 0.1,
});
const water = new THREE.Mesh(waterGeo, waterMat);
scene.add(water);
const waterBase = (waterGeo.attributes.position.array as Float32Array).slice();

// --- Islands --------------------------------------------------------------
type Island = { x: number; z: number; r: number };
const islands: Island[] = [];

function makeIsland(x: number, z: number, r: number) {
  const g = new THREE.Group();

  const sand = new THREE.Mesh(
    new THREE.CylinderGeometry(r, r * 1.25, 2.5, 7),
    new THREE.MeshStandardMaterial({ color: 0xe6d29a, flatShading: true })
  );
  sand.position.y = 0.2;
  g.add(sand);

  const grass = new THREE.Mesh(
    new THREE.ConeGeometry(r * 0.8, r * 0.7, 7),
    new THREE.MeshStandardMaterial({ color: 0x5fae54, flatShading: true })
  );
  grass.position.y = 1.4 + r * 0.25;
  g.add(grass);

  // a few palm-ish trees
  const trunkMat = new THREE.MeshStandardMaterial({ color: 0x7a5230, flatShading: true });
  const leafMat = new THREE.MeshStandardMaterial({ color: 0x3f8f47, flatShading: true });
  const trees = 2 + Math.floor(Math.random() * 3);
  for (let i = 0; i < trees; i++) {
    const a = Math.random() * Math.PI * 2;
    const rr = Math.random() * r * 0.45;
    const tx = Math.cos(a) * rr;
    const tz = Math.sin(a) * rr;
    const trunk = new THREE.Mesh(new THREE.CylinderGeometry(0.18, 0.28, 3.2, 5), trunkMat);
    trunk.position.set(tx, 2.6, tz);
    const leaves = new THREE.Mesh(new THREE.ConeGeometry(1.3, 1.6, 6), leafMat);
    leaves.position.set(tx, 4.4, tz);
    g.add(trunk, leaves);
  }

  g.position.set(x, 0, z);
  scene.add(g);
  islands.push({ x, z, r: r * 1.25 });
}

makeIsland(18, -22, 7);
makeIsland(-30, 10, 10);
makeIsland(40, 35, 6);
makeIsland(-10, 55, 8);
makeIsland(60, -40, 9);

// --- Boat -----------------------------------------------------------------
const boat = new THREE.Group();

const hull = new THREE.Mesh(
  new THREE.BoxGeometry(1.6, 0.7, 3.4),
  new THREE.MeshStandardMaterial({ color: 0x8a5a2b, flatShading: true })
);
hull.position.y = 0.45;
// taper the bow by squishing the front-top — quick low-poly hull feel
const deck = new THREE.Mesh(
  new THREE.BoxGeometry(1.4, 0.2, 3.0),
  new THREE.MeshStandardMaterial({ color: 0xb98a4f, flatShading: true })
);
deck.position.y = 0.85;

const mast = new THREE.Mesh(
  new THREE.CylinderGeometry(0.08, 0.1, 3.2, 5),
  new THREE.MeshStandardMaterial({ color: 0x5a3d22, flatShading: true })
);
mast.position.set(0, 2.4, 0.1);

const sail = new THREE.Mesh(
  new THREE.PlaneGeometry(1.6, 2.2),
  new THREE.MeshStandardMaterial({ color: 0xf3efe0, side: THREE.DoubleSide, flatShading: true })
);
sail.position.set(0, 2.4, 0.15);
sail.rotation.y = Math.PI / 2;

boat.add(hull, deck, mast, sail);
boat.position.set(0, 0, 0);
scene.add(boat);

// --- Boat physics ---------------------------------------------------------
let heading = 0;        // radians, 0 = +z
let speed = 0;          // current forward speed
const MAX_SPEED = 22;
const ACCEL = 14;
const DRAG = 1.6;
const TURN = 1.7;       // rad/s at full speed

// --- Input ----------------------------------------------------------------
const keys = new Set<string>();
addEventListener("keydown", (e) => keys.add(e.key.toLowerCase()));
addEventListener("keyup", (e) => keys.delete(e.key.toLowerCase()));

// Mobile: tap/hold a side to steer; boat sails forward on its own.
let touchSteer = 0;
let touching = false;
function setTouchFrom(x: number) { touchSteer = x < window.innerWidth / 2 ? 1 : -1; }
addEventListener("touchstart", (e) => { touching = true; setTouchFrom(e.touches[0].clientX); }, { passive: true });
addEventListener("touchmove", (e) => setTouchFrom(e.touches[0].clientX), { passive: true });
addEventListener("touchend", () => { touching = false; touchSteer = 0; });

function throttleInput(): number {
  if (touching) return 1; // auto-sail forward on mobile
  let t = 0;
  if (keys.has("w") || keys.has("arrowup")) t += 1;
  if (keys.has("s") || keys.has("arrowdown")) t -= 1;
  return t;
}
function steerInput(): number {
  let s = touchSteer;
  if (keys.has("a") || keys.has("arrowleft")) s += 1;
  if (keys.has("d") || keys.has("arrowright")) s -= 1;
  return Math.max(-1, Math.min(1, s));
}

// --- Resize ---------------------------------------------------------------
function resize() {
  const w = window.innerWidth, h = window.innerHeight;
  renderer.setSize(w, h);
  rt.setSize(Math.max(1, Math.floor(w * RES_SCALE)), Math.max(1, Math.floor(h * RES_SCALE)));
  const aspect = w / h;
  camera.left = (-VIEW * aspect) / 2;
  camera.right = (VIEW * aspect) / 2;
  camera.top = VIEW / 2;
  camera.bottom = -VIEW / 2;
  camera.updateProjectionMatrix();
}
addEventListener("resize", resize);
resize();

// --- Loop -----------------------------------------------------------------
const clock = new THREE.Clock();

function animateWater(t: number) {
  const pos = waterGeo.attributes.position.array as Float32Array;
  for (let i = 0; i < pos.length; i += 3) {
    const x = waterBase[i];
    const z = waterBase[i + 2];
    pos[i + 1] =
      Math.sin(x * 0.08 + t * 1.3) * 0.8 +
      Math.cos(z * 0.10 + t * 1.1) * 0.7;
  }
  waterGeo.attributes.position.needsUpdate = true;
  waterGeo.computeVertexNormals();
}

function tick() {
  const t = clock.getElapsedTime();
  const dt = Math.min(clock.getDelta(), 0.05);

  // physics
  const throttle = throttleInput();
  speed += throttle * ACCEL * dt;
  speed -= speed * DRAG * dt;             // water drag
  speed = Math.max(-MAX_SPEED * 0.4, Math.min(MAX_SPEED, speed));

  // can only steer meaningfully while moving
  const steerScale = Math.min(1, Math.abs(speed) / 6);
  heading += steerInput() * TURN * dt * steerScale * Math.sign(speed || 1);

  const nx = boat.position.x + Math.sin(heading) * speed * dt;
  const nz = boat.position.z + Math.cos(heading) * speed * dt;

  // island collision: stop & bounce back a touch
  let blocked = false;
  for (const is of islands) {
    const dx = nx - is.x, dz = nz - is.z;
    if (dx * dx + dz * dz < (is.r + 1.5) * (is.r + 1.5)) { blocked = true; break; }
  }
  if (blocked) {
    speed = -speed * 0.3;
  } else {
    boat.position.x = nx;
    boat.position.z = nz;
  }

  boat.rotation.y = heading;
  // bob the boat on the waves
  boat.position.y = Math.sin(t * 1.5) * 0.25;
  boat.rotation.z = Math.sin(t * 1.2) * 0.04;
  boat.rotation.x = Math.sin(t * 0.9) * 0.03;

  animateWater(t);

  // water + camera follow the boat so the world feels endless
  water.position.x = boat.position.x;
  water.position.z = boat.position.z;

  const camOffset = new THREE.Vector3(40, 50, -40);
  camera.position.copy(boat.position).add(camOffset);
  camera.lookAt(boat.position.x, 0, boat.position.z);

  // render low-res, then upscale to screen
  renderer.setRenderTarget(rt);
  renderer.render(scene, camera);
  renderer.setRenderTarget(null);
  renderer.render(screenScene, screenCam);

  requestAnimationFrame(tick);
}
tick();
