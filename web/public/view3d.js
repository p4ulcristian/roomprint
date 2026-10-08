// 3D view of space.json with three.js. z is up (as in space.json); the
// camera's up vector is set to +z so OrbitControls orbits around it.
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { CSS2DRenderer, CSS2DObject } from "three/addons/renderers/CSS2DRenderer.js";
import { PLYLoader } from "three/addons/loaders/PLYLoader.js";
import {
  bounds, wallFrame, along, wallOpenings, outwardSide, polygonCentroid, polygonArea,
  ROOM_COLORS, FURN_COLORS, hashColor,
} from "./geom.js";

export function create3D(container, space, { onRoom, pointsUrl } = {}) {
  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  container.appendChild(renderer.domElement);

  const labels = new CSS2DRenderer();
  Object.assign(labels.domElement.style, { position: "absolute", inset: "0", pointerEvents: "none" });
  container.appendChild(labels.domElement);

  const tip = document.createElement("div");
  tip.className = "tip hidden";
  container.appendChild(tip);

  const scene = new THREE.Scene();
  scene.background = new THREE.Color("#eef1f4");

  const b = bounds(space);
  const center = new THREE.Vector3((b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2, 0);
  const span = Math.max(b.maxX - b.minX, b.maxY - b.minY, 2);

  const camera = new THREE.PerspectiveCamera(45, 1, 0.05, span * 30);
  camera.up.set(0, 0, 1);
  // Portrait screens need the camera further back to fit the plan's width.
  const home = () => {
    const k = Math.max(1, 1.2 / camera.aspect);
    return { target: center.clone(), pos: center.clone().add(new THREE.Vector3(-0.35 * span, -1.0 * span, 1.05 * span).multiplyScalar(k)) };
  };
  camera.position.copy(home().pos);

  const controls = new OrbitControls(camera, renderer.domElement);
  controls.target.copy(center);
  controls.enableDamping = true;
  controls.maxPolarAngle = Math.PI * 0.49;
  controls.minDistance = 1;
  controls.maxDistance = span * 8;
  let userMoved = false;
  controls.addEventListener("start", () => { userMoved = true; anim = null; });

  // Lights
  scene.add(new THREE.HemisphereLight("#ffffff", "#c9c2b6", 2.2));
  const sun = new THREE.DirectionalLight("#ffffff", 1.3);
  sun.position.set(center.x - span * 0.6, center.y - span * 0.9, span * 1.6);
  sun.target.position.copy(center);
  sun.castShadow = true;
  sun.shadow.mapSize.set(2048, 2048);
  Object.assign(sun.shadow.camera, { left: -span, right: span, top: span, bottom: -span, near: 0.1, far: span * 5 });
  sun.shadow.bias = -0.0005;
  scene.add(sun, sun.target);

  // Ground
  const ground = new THREE.Mesh(
    new THREE.PlaneGeometry(span * 8, span * 8),
    new THREE.MeshStandardMaterial({ color: "#e4e7ea", roughness: 1 }),
  );
  ground.position.set(center.x, center.y, -0.02);
  ground.receiveShadow = true;
  scene.add(ground);

  // Floors (one per room) + labels
  const floors = [];
  space.rooms.forEach((r, i) => {
    const shape = new THREE.Shape(r.polygon.map(([x, y]) => new THREE.Vector2(x, y)));
    const mesh = new THREE.Mesh(
      new THREE.ShapeGeometry(shape),
      new THREE.MeshStandardMaterial({ color: ROOM_COLORS[i % ROOM_COLORS.length], roughness: 0.95 }),
    );
    mesh.position.z = 0.002;
    mesh.receiveShadow = true;
    mesh.userData.room = r;
    scene.add(mesh);
    floors.push(mesh);

    const el = document.createElement("div");
    el.className = "roomlabel";
    el.textContent = r.name || r.id;
    const label = new CSS2DObject(el);
    const [cx, cy] = polygonCentroid(r.polygon);
    label.position.set(cx, cy, 0.05);
    scene.add(label);
  });

  // Walls: boxes around each opening (below the sill, above the lintel, and solid stretches).
  const interiorMat = new THREE.MeshStandardMaterial({ color: "#f4f2ed", roughness: 0.9 });
  const edgeMat = new THREE.LineBasicMaterial({ color: "#8a8f96", transparent: true, opacity: 0.35 });
  const glassMat = new THREE.MeshStandardMaterial({ color: "#9cc8ee", transparent: true, opacity: 0.35, roughness: 0.1, depthWrite: false });
  const fadeable = [];   // exterior walls: { group, mat, normal, mid }

  for (const w of space.walls) {
    const f = wallFrame(w);
    if (f.L < 1e-3) continue;
    const t = w.thickness, H = w.height, h = t / 2;
    const outSide = outwardSide(space, w);
    const mat = outSide === null ? interiorMat : interiorMat.clone();
    const group = new THREE.Group();
    const meshes = [];

    const piece = (u0, u1, z0, z1) => {
      if (u1 - u0 < 1e-3 || z1 - z0 < 1e-3) return;
      const geo = new THREE.BoxGeometry(u1 - u0, t, z1 - z0);
      const m = new THREE.Mesh(geo, mat);
      const c = along(w, f, (u0 + u1) / 2);
      m.position.set(c[0], c[1], (z0 + z1) / 2);
      m.rotation.z = f.angle;
      m.castShadow = m.receiveShadow = true;
      const edges = new THREE.LineSegments(new THREE.EdgesGeometry(geo), edgeMat);
      m.add(edges);
      group.add(m);
      meshes.push(m);
    };

    const ops = wallOpenings(space, w);
    let u = -h;
    for (const o of ops) {
      if (o.u0 > u) piece(u, o.u0, 0, H);
      const top = Math.min(H, o.sill + o.height);
      piece(o.u0, o.u1, 0, o.sill);
      piece(o.u0, o.u1, top, H);
      if (o.type === "window") {
        const g = new THREE.Mesh(new THREE.BoxGeometry(o.u1 - o.u0, 0.02, top - o.sill), glassMat);
        const c = along(w, f, (o.u0 + o.u1) / 2);
        g.position.set(c[0], c[1], (o.sill + top) / 2);
        g.rotation.z = f.angle;
        group.add(g);
      }
      u = Math.max(u, o.u1);
    }
    if (f.L + h > u) piece(u, f.L + h, 0, H);
    scene.add(group);

    if (outSide !== null) {
      const mid = along(w, f, f.L / 2);
      fadeable.push({
        mat, meshes,
        normal: new THREE.Vector3(f.n[0] * outSide, f.n[1] * outSide, 0),
        mid: new THREE.Vector3(mid[0], mid[1], H / 2),
      });
    }
  }

  // Furniture
  const furniture = [];
  for (const o of space.objects) {
    const [sx, sy, sz] = o.size;
    const mesh = new THREE.Mesh(
      new THREE.BoxGeometry(sx, sy, sz),
      new THREE.MeshStandardMaterial({ color: hashColor(o.label, FURN_COLORS), roughness: 0.8 }),
    );
    mesh.position.set(...o.center);
    mesh.rotation.z = o.yaw;
    mesh.castShadow = mesh.receiveShadow = true;
    mesh.userData.object = o;
    scene.add(mesh);
    furniture.push(mesh);
  }

  // ---------- cut-away: fade exterior walls that face the camera ----------
  let cutaway = true;
  const tmp = new THREE.Vector3();
  function updateFade() {
    for (const w of fadeable) {
      const facing = cutaway && tmp.copy(camera.position).sub(w.mid).dot(w.normal) > 0;
      const want = facing ? 0.07 : 1;
      if (w.mat.opacity !== want) {
        w.mat.opacity = want;
        w.mat.transparent = want < 1;
        w.mat.depthWrite = want === 1;
        w.mat.needsUpdate = true;
        for (const m of w.meshes) m.castShadow = want === 1;
      }
    }
  }

  // ---------- camera animation ----------
  let anim = null;
  function flyTo(target, pos, ms = 650) {
    anim = { t0: performance.now(), ms, fromT: controls.target.clone(), fromP: camera.position.clone(), target, pos };
  }
  function stepAnim(now) {
    if (!anim) return;
    const k = Math.min(1, (now - anim.t0) / anim.ms);
    const e = k < 0.5 ? 2 * k * k : 1 - (-2 * k + 2) ** 2 / 2;
    controls.target.lerpVectors(anim.fromT, anim.target, e);
    camera.position.lerpVectors(anim.fromP, anim.pos, e);
    if (k === 1) anim = null;
  }

  let selected = null;
  function focusRoom(room) {
    for (const fl of floors) fl.material.emissive.set(fl.userData.room === room ? "#24476b" : "#000000");
    for (const fl of floors) fl.material.emissiveIntensity = 0.18;
    selected = room;
    if (!room) { const h = home(); flyTo(h.target, h.pos); onRoom?.(null); return; }
    const xs = room.polygon.map(p => p[0]), ys = room.polygon.map(p => p[1]);
    const size = Math.max(Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys), 2);
    const [cx, cy] = polygonCentroid(room.polygon);
    const target = new THREE.Vector3(cx, cy, 0.4);
    const dir = camera.position.clone().sub(controls.target);
    dir.z = 0;
    if (dir.lengthSq() < 1e-6) dir.set(0, -1, 0);
    dir.normalize().multiplyScalar(size * 1.0);
    const pos = target.clone().add(new THREE.Vector3(dir.x, dir.y, size * 1.25));
    flyTo(target, pos);
    onRoom?.({ room, area: Math.abs(polygonArea(room.polygon)), w: Math.max(...xs) - Math.min(...xs), d: Math.max(...ys) - Math.min(...ys) });
  }

  // ---------- picking ----------
  const ray = new THREE.Raycaster();
  const ndc = new THREE.Vector2();
  function pick(ev, list) {
    const r = renderer.domElement.getBoundingClientRect();
    ndc.set(((ev.clientX - r.left) / r.width) * 2 - 1, -((ev.clientY - r.top) / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    return ray.intersectObjects(list, false)[0] ?? null;
  }

  let hovered = null;
  function onMove(ev) {
    if (ev.pointerType === "touch") return;
    const hit = pick(ev, furniture);
    const obj = hit?.object ?? null;
    if (hovered !== obj) {
      if (hovered) hovered.material.emissive.set("#000000");
      hovered = obj;
      if (hovered) { hovered.material.emissive.set("#3a3a3a"); }
    }
    if (obj) {
      const r = container.getBoundingClientRect();
      const o = obj.userData.object;
      tip.textContent = `${o.label} · ${o.size.map(v => v.toFixed(2)).join(" × ")} m`;
      tip.style.left = `${ev.clientX - r.left}px`;
      tip.style.top = `${ev.clientY - r.top}px`;
      tip.classList.remove("hidden");
    } else tip.classList.add("hidden");
  }

  let down = null;
  const onDown = ev => { down = { x: ev.clientX, y: ev.clientY }; };
  const onUp = ev => {
    if (!down || Math.hypot(ev.clientX - down.x, ev.clientY - down.y) > 6) { down = null; return; }
    down = null;
    const fHit = pick(ev, furniture);
    if (fHit && ev.pointerType === "touch") {
      // Touch has no hover: show the label briefly on tap.
      onMove({ ...ev, pointerType: "mouse", clientX: ev.clientX, clientY: ev.clientY });
      setTimeout(() => tip.classList.add("hidden"), 1800);
    }
    let room = null;
    if (fHit) room = space.rooms.find(r => r.id === fHit.object.userData.object.room) ?? null;
    if (!room) room = pick(ev, floors)?.object.userData.room ?? null;
    focusRoom(room && room === selected ? null : room);
  };
  renderer.domElement.addEventListener("pointermove", onMove);
  renderer.domElement.addEventListener("pointerdown", onDown);
  renderer.domElement.addEventListener("pointerup", onUp);
  renderer.domElement.addEventListener("pointerleave", () => tip.classList.add("hidden"));

  // ---------- point cloud ----------
  let points = null, pointsLoading = null;
  async function setPoints(on) {
    if (on && !points) {
      pointsLoading ??= new PLYLoader().loadAsync(pointsUrl).then(geo => {
        const hasColor = !!geo.getAttribute("color");
        points = new THREE.Points(geo, new THREE.PointsMaterial({ size: 0.015, vertexColors: hasColor, color: hasColor ? "#ffffff" : "#3d6fa8" }));
        scene.add(points);
        return points;
      }).finally(() => { pointsLoading = null; });
      await pointsLoading;
    }
    if (points) points.visible = on;
  }

  // ---------- loop ----------
  function resize() {
    const w = container.clientWidth, h = container.clientHeight;
    if (!w || !h) return;
    renderer.setSize(w, h);
    labels.setSize(w, h);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
    if (!userMoved && !selected && !anim) camera.position.copy(home().pos);
  }
  const ro = new ResizeObserver(resize);
  ro.observe(container);
  resize();

  function frame(now) {
    stepAnim(now);
    controls.update();
    updateFade();
    renderer.render(scene, camera);
    labels.render(scene, camera);
  }

  return {
    setActive(on) { renderer.setAnimationLoop(on ? frame : null); if (on) resize(); },
    setCutaway(on) { cutaway = on; },
    setPoints,
    reset() { focusRoom(null); },
    dispose() { renderer.setAnimationLoop(null); ro.disconnect(); controls.dispose(); renderer.dispose(); container.innerHTML = ""; },
  };
}
