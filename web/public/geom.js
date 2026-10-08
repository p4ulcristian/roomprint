// Plain geometry over space.json, shared by the 3D view and the blueprint.
// Units are metres; floor plane is x/y, z up.

export const sub = (p, q) => [p[0] - q[0], p[1] - q[1]];
export const add = (p, q) => [p[0] + q[0], p[1] + q[1]];
export const mul = (p, k) => [p[0] * k, p[1] * k];
export const len = p => Math.hypot(p[0], p[1]);
export const norm = p => { const l = len(p) || 1; return [p[0] / l, p[1] / l]; };
export const perp = p => [-p[1], p[0]];
export const dot = (p, q) => p[0] * q[0] + p[1] * q[1];

export function polygonArea(poly) {
  let a = 0;
  for (let i = 0; i < poly.length; i++) {
    const [x1, y1] = poly[i], [x2, y2] = poly[(i + 1) % poly.length];
    a += x1 * y2 - x2 * y1;
  }
  return a / 2;
}

export function polygonCentroid(poly) {
  const a = polygonArea(poly);
  if (Math.abs(a) < 1e-9) {
    const n = poly.length || 1;
    return [poly.reduce((s, p) => s + p[0], 0) / n, poly.reduce((s, p) => s + p[1], 0) / n];
  }
  let cx = 0, cy = 0;
  for (let i = 0; i < poly.length; i++) {
    const [x1, y1] = poly[i], [x2, y2] = poly[(i + 1) % poly.length];
    const f = x1 * y2 - x2 * y1;
    cx += (x1 + x2) * f; cy += (y1 + y2) * f;
  }
  return [cx / (6 * a), cy / (6 * a)];
}

export function pointInPolygon([x, y], poly) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, yi] = poly[i], [xj, yj] = poly[j];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

export function bounds(space) {
  const pts = [
    ...space.rooms.flatMap(r => r.polygon),
    ...space.walls.flatMap(w => [w.a, w.b]),
  ];
  if (!pts.length) return { minX: 0, minY: 0, maxX: 1, maxY: 1 };
  return {
    minX: Math.min(...pts.map(p => p[0])), maxX: Math.max(...pts.map(p => p[0])),
    minY: Math.min(...pts.map(p => p[1])), maxY: Math.max(...pts.map(p => p[1])),
  };
}

// Fill in defaults so the views can rely on every field being present.
export function normalize(space) {
  const s = structuredClone(space);
  s.rooms ??= []; s.walls ??= []; s.openings ??= []; s.objects ??= [];
  const defH = s.rooms[0]?.height ?? 2.5;
  for (const r of s.rooms) r.height ??= defH;
  for (const w of s.walls) { w.thickness ??= 0.12; w.height ??= defH; w.rooms ??= []; }
  for (const o of s.openings) { o.sill ??= o.type === "window" ? 0.9 : 0; o.height ??= o.type === "window" ? 1.2 : 2.05; }
  for (const f of s.objects) { f.yaw ??= 0; f.label ??= "object"; }
  return s;
}

// A wall in its own frame: origin a, unit direction d, unit normal n (left of a->b).
export function wallFrame(w) {
  const v = sub(w.b, w.a);
  const L = len(v);
  const d = norm(v);
  return { L, d, n: perp(d), angle: Math.atan2(d[1], d[0]) };
}
export const along = (w, f, u, v = 0) => add(add(w.a, mul(f.d, u)), mul(f.n, v));

// Openings on a wall, clamped to the wall and sorted by offset.
export function wallOpenings(space, w) {
  const L = wallFrame(w).L;
  return space.openings
    .filter(o => o.wall === w.id)
    .map(o => ({ ...o, u0: Math.max(0, o.offset), u1: Math.min(L, o.offset + o.width) }))
    .filter(o => o.u1 > o.u0)
    .sort((a, b) => a.u0 - b.u0);
}

// Which side of the wall (+1 = normal side, -1) a room lies on.
export function roomSide(space, w, roomId) {
  const room = space.rooms.find(r => r.id === roomId);
  if (!room) return 1;
  const f = wallFrame(w);
  const c = polygonCentroid(room.polygon);
  const mid = along(w, f, f.L / 2);
  return dot(sub(c, mid), f.n) >= 0 ? 1 : -1;
}

// Outward side of an exterior wall (away from its only room); null if interior.
export function outwardSide(space, w) {
  if (w.rooms.length !== 1) return null;
  return -roomSide(space, w, w.rooms[0]);
}

// Door swing: into opening.swing (room id) if given, else into the wall's first room.
// Hinge at "a" (near edge) unless opening.hinge === "b".
export function doorSwing(space, w, o) {
  const target = o.swing ?? w.rooms[0];
  const side = target ? roomSide(space, w, target) : 1;
  return { side, hingeAtStart: o.hinge !== "b" };
}

export const fmtM = m => `${m.toFixed(2)} m`;

export const ROOM_COLORS = ["#dcebf7", "#f7e7d4", "#e0f0dc", "#efe0f3", "#f7f0c8", "#d9efee", "#f6dcdc"];
export const FURN_COLORS = ["#c9b79c", "#a9c1d9", "#b7cfa8", "#d6b3b3", "#c7bddf", "#e2cf9a", "#a8cfc8"];
export function hashColor(str, palette) {
  let h = 0;
  for (const c of String(str)) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return palette[h % palette.length];
}
