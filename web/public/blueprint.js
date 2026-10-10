// Blueprint: top-down architectural floor plan of space.json as one SVG.
// Drawing units are centimetres (1 m = 100 units); y is flipped so +y is up.
import {
  bounds, wallFrame, along, wallOpenings, outwardSide, roomSide, doorSwing,
  polygonArea, polygonCentroid, add, mul, sub, fmtM,
} from "./geom.js";

const S = 100;
const NS = "http://www.w3.org/2000/svg";
const INK = "#1f2a36";
const DIM = "#2f5f8f";

const esc = s => String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const r1 = n => Math.round(n * 10) / 10;

// Readable text angle (degrees, SVG frame) for a direction given in plan radians.
function textAngle(rad) {
  let deg = (-rad * 180) / Math.PI;
  while (deg > 90) deg -= 180;
  while (deg <= -90) deg += 180;
  return r1(deg);
}

export function renderBlueprint(space, { furniture = true } = {}) {
  const b = bounds(space);
  const pad = 130, padBottom = 200;
  const W = (b.maxX - b.minX) * S + pad * 2;
  const H = (b.maxY - b.minY) * S + pad + padBottom;
  const X = x => r1((x - b.minX) * S + pad);
  const Y = y => r1((b.maxY - y) * S + pad);
  const P = p => `${X(p[0])},${Y(p[1])}`;
  const poly = pts => pts.map(P).join(" ");
  const out = [];

  out.push(`<svg xmlns="${NS}" viewBox="0 0 ${r1(W)} ${r1(H)}" width="${r1(W)}" height="${r1(H)}" font-family="Helvetica, Arial, sans-serif">`);
  out.push(`<title>${esc(space.name || "Floor plan")}</title>`);
  out.push(`<style>
    .room{fill:#eef4fa;stroke:none}
    .wall{fill:${INK}}
    .win{fill:#fbfdff;stroke:${INK};stroke-width:1.5}
    .winl{stroke:${INK};stroke-width:1.2}
    .leaf{stroke:${INK};stroke-width:3;stroke-linecap:round}
    .swing{fill:none;stroke:${INK};stroke-width:1;stroke-dasharray:5 4}
    .unsure{stroke:#d9822b}
    .dim{stroke:${DIM};stroke-width:1.2;fill:none}
    .dimt{fill:${DIM};font-size:19px;text-anchor:middle;dominant-baseline:middle}
    .dimi{fill:#5d7187;font-size:15px;text-anchor:middle;dominant-baseline:middle}
    .rname{fill:${INK};font-size:26px;font-weight:700;text-anchor:middle}
    .rarea{fill:#4a5966;font-size:20px;text-anchor:middle}
    .halo{paint-order:stroke;stroke:#fbfdff;stroke-width:6px;stroke-linejoin:round}
    .furn{fill:#ffffff;fill-opacity:.55;stroke:#8e9aa6;stroke-width:1.2}
    .furnt{fill:#7b8794;font-size:12px;text-anchor:middle;dominant-baseline:middle}
    .foot{fill:${INK};font-size:18px}
  </style>`);
  out.push(`<rect width="100%" height="100%" fill="#fbfdff"/>`);

  // Rooms
  for (const r of space.rooms) out.push(`<polygon class="room" points="${poly(r.polygon)}"/>`);

  // Furniture under the walls and labels
  if (furniture) {
    for (const f of space.objects) {
      const [cx, cy] = f.center, [sx, sy] = f.size;
      const c = Math.cos(f.yaw), s = Math.sin(f.yaw);
      const corner = (u, v) => [cx + u * c - v * s, cy + u * s + v * c];
      const pts = [corner(-sx / 2, -sy / 2), corner(sx / 2, -sy / 2), corner(sx / 2, sy / 2), corner(-sx / 2, sy / 2)];
      out.push(`<polygon class="furn" points="${poly(pts)}"/>`);
      const longAxis = sx >= sy ? f.yaw : f.yaw + Math.PI / 2;
      if (Math.max(sx, sy) * S > esc(f.label).length * 6.5)
        out.push(`<text class="furnt" x="${X(cx)}" y="${Y(cy)}" transform="rotate(${textAngle(longAxis)} ${X(cx)} ${Y(cy)})">${esc(f.label)}</text>`);
    }
  }

  // Walls: solid pieces around openings, extended by half the thickness at both ends to close corners.
  for (const w of space.walls) {
    const f = wallFrame(w);
    const t = w.thickness, h = t / 2;
    const ops = wallOpenings(space, w);
    const solid = [];
    let u = -h;
    for (const o of ops) { if (o.u0 > u) solid.push([u, o.u0]); u = Math.max(u, o.u1); }
    if (f.L + h > u) solid.push([u, f.L + h]);
    for (const [u0, u1] of solid)
      out.push(`<polygon class="wall" points="${poly([along(w, f, u0, -h), along(w, f, u1, -h), along(w, f, u1, h), along(w, f, u0, h)])}"/>`);

    for (const o of ops) {
      // the vision model saw it in only one frame: drawn in amber for the user to check
      const un = o.sure === false ? " unsure" : "";
      if (o.type === "window") {
        out.push(`<polygon class="win${un}" points="${poly([along(w, f, o.u0, -h), along(w, f, o.u1, -h), along(w, f, o.u1, h), along(w, f, o.u0, h)])}"/>`);
        for (const v of [-t / 6, t / 6]) {
          const p0 = along(w, f, o.u0, v), p1 = along(w, f, o.u1, v);
          out.push(`<line class="winl${un}" x1="${X(p0[0])}" y1="${Y(p0[1])}" x2="${X(p1[0])}" y2="${Y(p1[1])}"/>`);
        }
      } else {
        const { side, hingeAtStart } = doorSwing(space, w, o);
        const width = o.u1 - o.u0;
        const hu = hingeAtStart ? o.u0 : o.u1;
        const hinge = along(w, f, hu, side * h);
        const open = mul(f.n, side);                     // leaf direction when open (perpendicular)
        const toward = mul(f.d, hingeAtStart ? 1 : -1);  // closed direction along the wall
        const leafEnd = add(hinge, mul(open, width));
        out.push(`<line class="leaf${un}" x1="${X(hinge[0])}" y1="${Y(hinge[1])}" x2="${X(leafEnd[0])}" y2="${Y(leafEnd[1])}"/>`);
        const arc = [];
        for (let i = 0; i <= 16; i++) {
          const a = (i / 16) * (Math.PI / 2);
          arc.push(add(hinge, add(mul(open, width * Math.cos(a)), mul(toward, width * Math.sin(a)))));
        }
        out.push(`<polyline class="swing${un}" points="${poly(arc)}"/>`);
      }
    }
  }

  // Dimensions: exterior walls get a full dimension line outside; interior walls a small label.
  for (const w of space.walls) {
    const f = wallFrame(w);
    if (f.L < 0.2) continue;
    const h = w.thickness / 2;
    const out_ = outwardSide(space, w);
    const label = fmtM(f.L);
    const ang = textAngle(f.angle);
    if (out_ !== null) {
      const off = out_ * (h + 0.45);
      const p0 = along(w, f, 0, off), p1 = along(w, f, f.L, off);
      out.push(`<line class="dim" x1="${X(p0[0])}" y1="${Y(p0[1])}" x2="${X(p1[0])}" y2="${Y(p1[1])}"/>`);
      for (const u of [0, f.L]) {
        const e0 = along(w, f, u, out_ * (h + 0.08)), e1 = along(w, f, u, out_ * (h + 0.55));
        out.push(`<line class="dim" x1="${X(e0[0])}" y1="${Y(e0[1])}" x2="${X(e1[0])}" y2="${Y(e1[1])}"/>`);
        // 45-degree architectural tick
        const c = along(w, f, u, off);
        const k = add(mul(f.d, 0.07), mul(f.n, 0.07));
        const t0 = sub(c, k), t1 = add(c, k);
        out.push(`<line class="dim" style="stroke-width:2.2" x1="${X(t0[0])}" y1="${Y(t0[1])}" x2="${X(t1[0])}" y2="${Y(t1[1])}"/>`);
      }
      const tp = along(w, f, f.L / 2, off + out_ * 0.16);
      out.push(`<text class="dimt halo" x="${X(tp[0])}" y="${Y(tp[1])}" transform="rotate(${ang} ${X(tp[0])} ${Y(tp[1])})">${label}</text>`);
    } else {
      const side = w.rooms[0] ? roomSide(space, w, w.rooms[0]) : 1;
      const tp = along(w, f, f.L / 2, side * (h + 0.17));
      out.push(`<text class="dimi halo" x="${X(tp[0])}" y="${Y(tp[1])}" transform="rotate(${ang} ${X(tp[0])} ${Y(tp[1])})">${label}</text>`);
    }
  }

  // Room names and areas
  for (const r of space.rooms) {
    const [cx, cy] = polygonCentroid(r.polygon);
    const area = Math.abs(polygonArea(r.polygon));
    out.push(`<text class="rname halo" x="${X(cx)}" y="${Y(cy) - 4}">${esc(r.name || r.id)}</text>`);
    out.push(`<text class="rarea halo" x="${X(cx)}" y="${Y(cy) + 22}">${area.toFixed(1)} m²</text>`);
  }

  // Scale bar (2 m in 0.5 m blocks) and footer
  const sx = pad, sy = H - padBottom / 2 + 10;
  for (let i = 0; i < 4; i++)
    out.push(`<rect x="${sx + i * 50}" y="${sy}" width="50" height="10" fill="${i % 2 ? "#fbfdff" : INK}" stroke="${INK}" stroke-width="1.2"/>`);
  for (const m of [0, 1, 2]) out.push(`<text class="foot" style="font-size:15px" x="${sx + m * 100}" y="${sy + 32}" text-anchor="middle">${m}${m === 2 ? " m" : ""}</text>`);
  const total = space.rooms.reduce((s, r) => s + Math.abs(polygonArea(r.polygon)), 0);
  out.push(`<text class="foot" x="${r1(W - pad)}" y="${sy + 4}" text-anchor="end" font-weight="700">${esc(space.name || "Floor plan")}</text>`);
  out.push(`<text class="foot" style="font-size:14px;fill:#5d6b78" x="${r1(W - pad)}" y="${sy + 26}" text-anchor="end">${space.rooms.length} room${space.rooms.length === 1 ? "" : "s"} · ${total.toFixed(1)} m² · wall lengths on centre lines · Roomprint</text>`);
  out.push(`</svg>`);
  return out.join("\n");
}
