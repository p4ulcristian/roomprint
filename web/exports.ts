// Exports of a space: each is built on first request and kept in the space's exports/
// folder until what it was made from changes.
//
//   GET /api/s/<token>/export/<kind>.<format>[?crop=x0,y0,z0,x1,y1,z1]
//
//   mesh    glb obj usdz stl ply      the real scan            worker/export.py
//   points  ply las xyz               its point cloud          worker/export.py
//   model   glb obj usdz stl          the drawn model          worker/export.py
//   plan    svg pdf png dxf           the floor plan           drawn here (blueprint.js); dxf by the worker
//   raw     zip                       photos, depth, poses     worker/export.py
//   splat   ply                       the Gaussian splat       the file as trained
//
// crop (plan coordinates, metres) applies to mesh and points.
import { join } from "path";
import { existsSync, mkdirSync, statSync, readdirSync, unlinkSync, renameSync } from "fs";
import { spaceDir, readJson, type Meta } from "./store";
import { renderBlueprint } from "./public/blueprint.js";
import { normalize } from "./public/geom.js";

const WORKER = join(import.meta.dir, "..", "worker");
const PYTHON = process.env.WORKER_PYTHON ?? join(WORKER, ".venv", "bin", "python");
const BUILD_MS = 240_000;

const FORMATS: Record<string, string[]> = {
  mesh: ["glb", "obj", "usdz", "stl", "ply"],
  points: ["ply", "las", "xyz"],
  model: ["glb", "obj", "usdz", "stl"],
  plan: ["svg", "pdf", "png", "dxf"],
  raw: ["zip"],
  splat: ["ply"],
};
const TYPES: Record<string, string> = {
  glb: "model/gltf-binary", usdz: "model/vnd.usdz+zip", stl: "model/stl", ply: "application/octet-stream",
  obj: "application/zip", zip: "application/zip", las: "application/octet-stream", xyz: "text/plain",
  svg: "image/svg+xml", pdf: "application/pdf", png: "image/png", dxf: "application/dxf",
};
// The download's name: <space>-<what>.<ext>; an obj comes zipped with its texture.
const WHAT: Record<string, string> = { mesh: "scan", points: "points", model: "model", plan: "floor-plan", raw: "raw", splat: "splat" };

const mtime = (f: string) => { try { return statSync(f).mtimeMs; } catch { return 0; } };
const newestUpload = (dir: string, ext: string) =>
  Math.max(0, ...(existsSync(join(dir, "uploads")) ? readdirSync(join(dir, "uploads")) : [])
    .filter(f => f.endsWith("." + ext)).map(f => mtime(join(dir, "uploads", f))));

// When each kind's source last changed; 0 if the space has nothing to make it from.
function sources(id: string): Record<string, number> {
  const dir = spaceDir(id);
  const space = readJson<{ rooms?: unknown[]; lidar_frame?: unknown }>(join(dir, "space.json"));
  const plan = space?.rooms?.length ? mtime(join(dir, "space.json")) : 0;
  const scan = Math.max(mtime(join(dir, "textured.glb")), mtime(join(dir, "mesh.ply")));
  const depth = newestUpload(dir, "rgbd");
  return {
    mesh: scan,
    points: scan || mtime(join(dir, "preview.ply")),
    model: plan,
    plan,
    raw: space?.lidar_frame && depth ? Math.max(depth, mtime(join(dir, "space.json"))) : 0,
    splat: mtime(join(dir, "splat.ply")),
  };
}

/** The exports a space can make right now: { kind: [formats] }. */
export function exportsOf(id: string): Record<string, string[]> {
  const src = sources(id);
  return Object.fromEntries(Object.entries(FORMATS).filter(([kind]) => src[kind] > 0));
}

const building = new Map<string, Promise<string | null>>();   // one build per file at a time

async function run(cmd: string[]): Promise<string | null> {
  const proc = Bun.spawn(cmd, { stdout: "ignore", stderr: "pipe" });
  const timer = setTimeout(() => proc.kill(), BUILD_MS);
  const [code, errText] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
  clearTimeout(timer);
  if (code === 0) return null;
  console.error(`export failed (${code}): ${cmd.slice(1).join(" ")}\n${errText}`);
  // exit 3: the worker's own message for the person (nothing inside the crop box, ...)
  return code === 3 ? errText.trim().split("\n").pop()! : "the export could not be made";
}

async function drawPlan(id: string, fmt: string, out: string): Promise<string | null> {
  const space = normalize(readJson(join(spaceDir(id), "space.json")));
  let svg = `<?xml version="1.0" encoding="UTF-8"?>\n` + renderBlueprint(space, { furniture: true });
  if (fmt === "svg") { await Bun.write(out, svg); return null; }
  // The drawing's unit is 1 cm of the flat. Sized in mm at 0.2 mm a unit, the PDF's page is the plan at 1:50.
  if (fmt === "pdf") svg = svg.replace(/ width="([\d.]+)" height="([\d.]+)"/, (_, w, h) => ` width="${w * 0.2}mm" height="${h * 0.2}mm"`);
  await Bun.write(out + ".svg", svg);
  const failed = await run(["rsvg-convert", "-f", fmt, ...(fmt === "png" ? ["-w", "3000"] : []), "-o", out, out + ".svg"]);
  try { unlinkSync(out + ".svg"); } catch {}
  return failed;
}

function parseCrop(v: string | null): string | null | undefined {
  if (!v) return null;
  const n = v.split(",").map(Number);
  if (n.length !== 6 || n.some(x => !Number.isFinite(x) || Math.abs(x) > 1000)) return undefined;
  if (n[0] >= n[3] || n[1] >= n[4] || n[2] >= n[5]) return undefined;
  return n.map(x => x.toFixed(2)).join(",");
}

export async function exportFile(meta: Meta, kind: string, fmt: string, url: URL): Promise<Response> {
  const bad = (msg: string, status = 400) => Response.json({ error: msg }, { status });
  if (!FORMATS[kind]?.includes(fmt)) return bad("no such export", 404);
  const changed = sources(meta.id)[kind];
  if (!changed) return bad("this space has nothing to make that from yet", 404);
  const crop = ["mesh", "points"].includes(kind) ? parseCrop(url.searchParams.get("crop")) : null;
  if (crop === undefined) return bad("bad crop box");

  const dir = join(spaceDir(meta.id), "exports");
  const base = `${kind}.${fmt}`;
  const file = join(dir, crop ? `crop_${crop.replaceAll(",", "_")}_${base}` : base);
  const source = kind === "splat" ? join(spaceDir(meta.id), "splat.ply") : file;
  if (kind !== "splat" && mtime(file) < changed) {
    mkdirSync(dir, { recursive: true });
    let job = building.get(file);
    if (!job) {
      job = (async () => {
        // only the latest crop of a file is kept
        if (crop) for (const f of readdirSync(dir)) if (f.startsWith("crop_") && f.endsWith("_" + base)) try { unlinkSync(join(dir, f)); } catch {}
        const tmp = join(dir, `tmp-${base}`);
        const failed = kind === "plan" && fmt !== "dxf"
          ? await drawPlan(meta.id, fmt, tmp)
          : await run([PYTHON, join(WORKER, "export.py"), spaceDir(meta.id), kind, fmt, tmp, ...(crop ? [crop] : [])]);
        if (!failed) renameSync(tmp, file);
        return failed;
      })().finally(() => building.delete(file));
      building.set(file, job);
    }
    const failed = await job;
    if (failed) return bad(failed, 500);
  }

  const safe = meta.name.replace(/[^\w\- ]+/g, "").trim().replace(/\s+/g, "-") || "space";
  const ext = fmt === "obj" ? "obj.zip" : fmt;
  return new Response(Bun.file(source), {
    headers: {
      "content-type": TYPES[fmt] ?? "application/octet-stream",
      "content-disposition": `attachment; filename="${safe}-${WHAT[kind]}${crop ? "-cropped" : ""}.${ext}"`,
      "cache-control": "no-cache",
    },
  });
}
