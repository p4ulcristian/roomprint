// Roomprint web: invite-link upload page, chunked uploads, status, and the
// 3D / blueprint viewer over space.json. The GPU worker (worker/) reads and
// writes the same data dir; this server only ever sets state draft/queued.
//
// Pages:   /  about Roomprint, TestFlight, contact form (POST /api/contact)
//          /u/<token>  upload (phone)      /s/<token>  viewer
//          /admin/<ADMIN_TOKEN>  every space, newest first (GET /api/admin/<ADMIN_TOKEN>)
// API:     POST   /api/spaces  {name}  (Bearer APP_SECRET, the iOS app) -> {token, name}
//          GET    /api/s/<token>                     meta, status, clips, files present
//          POST   /api/s/<token>/meta                {capture?, wall_length_m?, note?}
//          POST   /api/s/<token>/clips               {filename, bytes, room_name?} -> {id, received}
//          GET    /api/s/<token>/clips/<clip>        {id, received, bytes, complete}
//          PUT    /api/s/<token>/clips/<clip>?offset=N   raw chunk body -> {received, complete}
//          DELETE /api/s/<token>/clips/<clip>
//          GET    /api/s/<token>/clips/<clip>/file   the uploaded file (Range requests, for video)
//          POST   /api/s/<token>/submit              -> status queued
//          GET    /api/s/<token>/status | space.json | preview.ply
import { join, extname } from "path";
import { existsSync, mkdirSync, statSync, renameSync, unlinkSync } from "fs";
import { open } from "fs/promises";
import { randomBytes, timingSafeEqual } from "crypto";
import { mailConfigured, sendMail } from "./mail";
import {
  DATA_DIR, spaceDir, byToken, createSpace, listSpaces, getStatus, setStatus, listClips, listPending,
  readJson, writeJson, now, type Meta, type Pending, type Clip,
} from "./store";

const PORT = Number(process.env.PORT ?? 4490);
const LOCAL_HOST = "127.0.0.1";
const TUNNEL_HOST = process.env.TUNNEL_HOST;
const PUBLIC = join(import.meta.dir, "public");
const APP_SECRET = process.env.APP_SECRET ?? "";   // the iOS app's key for creating spaces
const ADMIN_TOKEN = process.env.ADMIN_TOKEN ?? "";  // the overview page's secret path

const CHUNK_MAX = 16 * 1024 * 1024;           // client sends 8 MB; allow some slack
const FILE_MAX = 8 * 1024 * 1024 * 1024;      // 8 GB per clip
const VIDEO_EXT = ["mov", "mp4", "m4v", "webm", "3gp", "mkv"];
const LIDAR_EXT = ["usdz", "obj", "glb", "gltf", "ply", "zip", "roomplan"];  // .roomplan: the iOS app's scan
const EXTS = new Set([...VIDEO_EXT, ...LIDAR_EXT]);
const LOCKED = new Set(["queued", "processing"]);   // no upload changes while the worker owns it

const json = (data: unknown, status = 200) => Response.json(data, { status });
const err = (msg: string, status = 400) => json({ error: msg }, status);

function page(name: string): Response {
  return new Response(Bun.file(join(PUBLIC, name)), {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "no-referrer" },
  });
}

function staticFile(path: string): Response | null {
  const rel = path.replace(/^\/static\//, "");
  if (rel.includes("..") || !/^[\w.-]+$/.test(rel)) return null;
  const f = join(PUBLIC, rel);
  if (!existsSync(f)) return null;
  return new Response(Bun.file(f), { headers: { "cache-control": "no-cache" } });
}

function summary(meta: Meta) {
  const dir = spaceDir(meta.id);
  const { token: _t, ...pub } = meta;
  return {
    meta: pub,
    status: getStatus(meta.id),
    clips: listClips(meta.id),
    pending: listPending(meta.id).map(p => ({ ...p, received: partSize(meta.id, p) })),
    has_space: existsSync(join(dir, "space.json")),
    has_preview: existsSync(join(dir, "preview.ply")),
  };
}

const partPath = (id: string, p: Pending) => join(spaceDir(id), "incoming", `${p.id}.${p.ext}.part`);
const pendingPath = (id: string, clip: string) => join(spaceDir(id), "incoming", `${clip}.json`);
function partSize(id: string, p: Pending) {
  try { return statSync(partPath(id, p)).size; } catch { return 0; }
}
const validClip = (c: string) => /^c_[0-9a-f]{8}$/.test(c);

async function createClip(meta: Meta, req: Request): Promise<Response> {
  if (LOCKED.has(getStatus(meta.id).state)) return err("space is being processed", 409);
  const body = await req.json().catch(() => null);
  const filename = String(body?.filename ?? "").slice(0, 200);
  const bytes = Number(body?.bytes);
  const room_name = body?.room_name ? String(body.room_name).trim().slice(0, 80) || null : null;
  const ext = extname(filename).slice(1).toLowerCase();
  if (!filename || !EXTS.has(ext)) return err(`unsupported file type .${ext}`);
  if (!Number.isInteger(bytes) || bytes <= 0 || bytes > FILE_MAX) return err("bad size");

  // Resume: the same file (name + size) that is still incoming keeps its id.
  const existing = listPending(meta.id).find(p => p.filename === filename && p.bytes === bytes);
  if (existing) {
    if (existing.room_name !== room_name) {
      existing.room_name = room_name;
      writeJson(pendingPath(meta.id, existing.id), existing);
    }
    return json({ id: existing.id, received: partSize(meta.id, existing), bytes });
  }

  const p: Pending = { id: "c_" + randomBytes(4).toString("hex"), room_name, filename, bytes, ext, started: now() };
  mkdirSync(join(spaceDir(meta.id), "incoming"), { recursive: true });
  await Bun.write(partPath(meta.id, p), "");
  writeJson(pendingPath(meta.id, p.id), p);
  return json({ id: p.id, received: 0, bytes });
}

function clipInfo(meta: Meta, clip: string): Response {
  const p = readJson<Pending>(pendingPath(meta.id, clip));
  if (p) return json({ id: clip, received: partSize(meta.id, p), bytes: p.bytes, complete: false });
  const c = readJson<Clip>(join(spaceDir(meta.id), "uploads", `${clip}.json`));
  if (c) return json({ id: clip, received: c.bytes, bytes: c.bytes, complete: true });
  return err("no such clip", 404);
}

async function putChunk(meta: Meta, clip: string, req: Request, url: URL): Promise<Response> {
  if (LOCKED.has(getStatus(meta.id).state)) return err("space is being processed", 409);
  const p = readJson<Pending>(pendingPath(meta.id, clip));
  if (!p) {
    if (existsSync(join(spaceDir(meta.id), "uploads", `${clip}.json`))) return json({ received: -1, complete: true });
    return err("no such clip", 404);
  }
  const offset = Number(url.searchParams.get("offset"));
  const have = partSize(meta.id, p);
  // The client must continue exactly where the server is; otherwise it re-syncs.
  if (offset !== have) return json({ error: "offset mismatch", received: have }, 409);
  const data = new Uint8Array(await req.arrayBuffer());
  if (data.length === 0 || data.length > CHUNK_MAX) return err("bad chunk size");
  if (have + data.length > p.bytes) return err("chunk past end of file");

  const fh = await open(partPath(meta.id, p), "r+");
  try { await fh.write(data, 0, data.length, have); } finally { await fh.close(); }
  const received = have + data.length;

  if (received === p.bytes) {
    const dir = join(spaceDir(meta.id), "uploads");
    mkdirSync(dir, { recursive: true });
    renameSync(partPath(meta.id, p), join(dir, `${p.id}.${p.ext}`));
    const c: Clip = { id: p.id, room_name: p.room_name, filename: p.filename, bytes: p.bytes, uploaded: now() };
    writeJson(join(dir, `${p.id}.json`), c);
    unlinkSync(pendingPath(meta.id, p.id));
    return json({ received, complete: true });
  }
  return json({ received, complete: false });
}

function deleteClip(meta: Meta, clip: string): Response {
  if (LOCKED.has(getStatus(meta.id).state)) return err("space is being processed", 409);
  const p = readJson<Pending>(pendingPath(meta.id, clip));
  if (p) {
    try { unlinkSync(partPath(meta.id, p)); } catch {}
    unlinkSync(pendingPath(meta.id, clip));
    return json({ ok: true });
  }
  const dir = join(spaceDir(meta.id), "uploads");
  const c = readJson<Clip>(join(dir, `${clip}.json`));
  if (!c) return err("no such clip", 404);
  const ext = extname(c.filename).slice(1).toLowerCase();
  try { unlinkSync(join(dir, `${clip}.${ext}`)); } catch {}
  unlinkSync(join(dir, `${clip}.json`));
  return json({ ok: true });
}

const FILE_TYPES: Record<string, string> = {
  // .mov from iPhones is H.264/HEVC in QuickTime; browsers play it when told it is MP4
  mov: "video/mp4", mp4: "video/mp4", m4v: "video/mp4", webm: "video/webm", "3gp": "video/3gpp", mkv: "video/x-matroska",
  usdz: "model/vnd.usdz+zip", glb: "model/gltf-binary", gltf: "model/gltf+json", obj: "text/plain",
  ply: "application/octet-stream", zip: "application/zip", roomplan: "application/json",
};

function clipFile(meta: Meta, clip: string, req: Request): Response {
  const c = readJson<Clip>(join(spaceDir(meta.id), "uploads", `${clip}.json`));
  if (!c) return err("no such clip", 404);
  const ext = extname(c.filename).slice(1).toLowerCase();
  const path = join(spaceDir(meta.id), "uploads", `${clip}.${ext}`);
  if (!existsSync(path)) return err("no such clip", 404);
  const file = Bun.file(path);
  const size = file.size;
  const headers: Record<string, string> = {
    "content-type": FILE_TYPES[ext] ?? "application/octet-stream",
    "accept-ranges": "bytes",
    "cache-control": "private, max-age=3600",
    "content-disposition": `inline; filename="${c.filename.replace(/[^\w.-]/g, "_")}"`,
  };
  const range = req.headers.get("range")?.match(/^bytes=(\d*)-(\d*)$/);
  if (range && (range[1] || range[2])) {
    let start = range[1] ? Number(range[1]) : size - Number(range[2]);
    let end = range[1] && range[2] ? Number(range[2]) : size - 1;
    start = Math.max(0, start); end = Math.min(size - 1, end);
    if (start > end) return new Response(null, { status: 416, headers: { "content-range": `bytes */${size}` } });
    return new Response(file.slice(start, end + 1), {
      status: 206, headers: { ...headers, "content-range": `bytes ${start}-${end}/${size}`, "content-length": String(end - start + 1) },
    });
  }
  return new Response(file, { headers: { ...headers, "content-length": String(size) } });
}

async function updateMeta(meta: Meta, req: Request): Promise<Response> {
  if (LOCKED.has(getStatus(meta.id).state)) return err("space is being processed", 409);
  const body = await req.json().catch(() => ({}));
  if (body.capture === "walkthrough" || body.capture === "per-room") meta.capture = body.capture;
  if ("wall_length_m" in body) {
    const v = body.wall_length_m === null || body.wall_length_m === "" ? null : Number(body.wall_length_m);
    if (v !== null && !(v > 0.3 && v < 100)) return err("wall length should be between 0.3 and 100 m");
    meta.scale.wall_length_m = v;
  }
  if (typeof body.note === "string") meta.scale.note = body.note.slice(0, 500);
  writeJson(join(spaceDir(meta.id), "meta.json"), meta);
  return json(summary(meta));
}

function submit(meta: Meta): Response {
  const st = getStatus(meta.id).state;
  if (LOCKED.has(st)) return err("already queued", 409);
  if (listPending(meta.id).length) return err("some uploads are not finished yet", 409);
  if (!listClips(meta.id).length) return err("upload at least one video first", 409);
  setStatus(meta.id, { state: "queued", step: "waiting for the GPU", progress: 0, error: null });
  return json(summary(meta));
}

// The iOS app makes its own spaces instead of waiting for an invite link.
async function newSpace(req: Request): Promise<Response> {
  const auth = Buffer.from(req.headers.get("authorization") ?? "");
  const want = Buffer.from(`Bearer ${APP_SECRET}`);
  if (!APP_SECRET || auth.length !== want.length || !timingSafeEqual(auth, want)) return err("not allowed", 403);
  const body = await req.json().catch(() => ({}));
  const name = String(body?.name ?? "").trim().slice(0, 80) || "New space";
  const meta = createSpace(name);
  return json({ token: meta.token, name: meta.name });
}

const isAdmin = (t: string) => {
  const a = Buffer.from(t), b = Buffer.from(ADMIN_TOKEN);
  return ADMIN_TOKEN.length >= 16 && a.length === b.length && timingSafeEqual(a, b);
};

// Every space for the overview page: newest first, with its rooms and uploads.
function adminList(): Response {
  const spaces = listSpaces().reverse().map(meta => {
    const sp = readJson<{ rooms: { name: string; polygon: number[][] }[] }>(join(spaceDir(meta.id), "space.json"));
    const area = (poly: number[][]) => Math.abs(poly.reduce((a, [x, y], i) => {
      const [x2, y2] = poly[(i + 1) % poly.length];
      return a + x * y2 - x2 * y;
    }, 0)) / 2;
    return {
      id: meta.id, name: meta.name, token: meta.token, created: meta.created,
      status: getStatus(meta.id),
      clips: listClips(meta.id).map(c => ({ id: c.id, filename: c.filename, bytes: c.bytes, uploaded: c.uploaded })),
      pending: listPending(meta.id).length,
      rooms: sp?.rooms.map(r => ({ name: r.name, area: Math.round(area(r.polygon) * 10) / 10 })) ?? null,
    };
  });
  return json({ spaces });
}

// Contact form: every message is kept in DATA_DIR/messages and, when mail is set up,
// emailed to MAIL_TO with Reply-To set to the sender. A hidden "website" field and a
// per-address limit keep bots out.
const recent = new Map<string, number[]>();
async function contact(req: Request): Promise<Response> {
  const ip = req.headers.get("x-forwarded-for")?.split(",")[0].trim() || "local";
  const now = Date.now();
  const hits = (recent.get(ip) ?? []).filter(t => now - t < 3600_000);
  if (hits.length >= 5) return err("too many messages, try again later", 429);
  const body = await req.json().catch(() => null);
  if (!body) return err("bad request");
  if (body.website) return json({ ok: true });   // honeypot: bots fill every field
  const name = String(body.name ?? "").trim().slice(0, 100);
  const email = String(body.email ?? "").trim().slice(0, 200);
  const message = String(body.message ?? "").trim().slice(0, 5000);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return err("please give an email address we can answer");
  if (message.length < 2) return err("please write a message");
  hits.push(now);
  recent.set(ip, hits);

  const dir = join(DATA_DIR, "messages");
  mkdirSync(dir, { recursive: true });
  const rec = { at: new Date(now).toISOString(), name, email, message, ip, mailed: false };
  const file = join(dir, `${rec.at.replace(/[:.]/g, "-")}.json`);
  if (mailConfigured()) {
    try {
      await sendMail(`Roomprint: message from ${name || email}`,
        `${message}\n\n-- \n${name ? name + " " : ""}<${email}>\nSent from the Roomprint contact form.`, email);
      rec.mailed = true;
    } catch (e) {
      console.error("contact mail failed:", e);
    }
  }
  writeJson(file, rec);
  return json({ ok: true });
}

function spaceFile(meta: Meta, name: string, type: string): Response {
  const f = join(spaceDir(meta.id), name);
  if (!existsSync(f)) return err("not ready", 404);
  return new Response(Bun.file(f), { headers: { "content-type": type, "cache-control": "no-cache" } });
}

async function handle(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const path = url.pathname;
  const m = req.method;

  if (path === "/" && m === "GET") return page("index.html");
  if (path === "/api/contact" && m === "POST") return contact(req);
  if (path.startsWith("/static/")) return staticFile(path) ?? err("not found", 404);

  const a = path.match(/^\/(api\/)?admin\/([\w-]+)\/?$/);
  if (a && m === "GET") {
    if (!isAdmin(a[2])) return err("not found", 404);
    return a[1] ? adminList() : page("admin.html");
  }

  let r = path.match(/^\/([us])\/([\w-]+)\/?$/);
  if (r && m === "GET") {
    if (!byToken(r[2])) return new Response("This link is not valid.", { status: 404 });
    return page(r[1] === "u" ? "upload.html" : "viewer.html");
  }

  if (path === "/api/spaces" && m === "POST") return newSpace(req);

  r = path.match(/^\/api\/s\/([\w-]+)(\/.*)?$/);
  if (!r) return err("not found", 404);
  const meta = byToken(r[1]);
  if (!meta) return err("unknown link", 404);
  const sub = r[2] ?? "";

  if (sub === "" && m === "GET") return json(summary(meta));
  if (sub === "/status" && m === "GET") return json(getStatus(meta.id));
  if (sub === "/meta" && m === "POST") return updateMeta(meta, req);
  if (sub === "/submit" && m === "POST") return submit(meta);
  if (sub === "/space.json" && m === "GET") return spaceFile(meta, "space.json", "application/json");
  if (sub === "/preview.ply" && m === "GET") return spaceFile(meta, "preview.ply", "application/octet-stream");
  if (sub === "/clips" && m === "POST") return createClip(meta, req);

  const f = sub.match(/^\/clips\/([\w-]+)\/file$/);
  if (f && validClip(f[1]) && m === "GET") return clipFile(meta, f[1], req);

  const c = sub.match(/^\/clips\/([\w-]+)$/);
  if (c && validClip(c[1])) {
    if (m === "GET") return clipInfo(meta, c[1]);
    if (m === "PUT") return putChunk(meta, c[1], req, url);
    if (m === "DELETE") return deleteClip(meta, c[1]);
  }
  return err("not found", 404);
}

async function safe(req: Request): Promise<Response> {
  try { return await handle(req); }
  catch (e) { console.error(e); return err("server error", 500); }
}

// maxRequestBodySize covers one chunk; whole videos never arrive in one request.
const opts = { port: PORT, idleTimeout: 120, maxRequestBodySize: CHUNK_MAX + 1024 * 1024, fetch: safe };
Bun.serve({ hostname: LOCAL_HOST, ...opts });
console.log(`roomprint on http://${LOCAL_HOST}:${PORT} (data ${DATA_DIR})`);
if (TUNNEL_HOST) {
  Bun.serve({ hostname: TUNNEL_HOST, ...opts });
  console.log(`roomprint on http://${TUNNEL_HOST}:${PORT}`);
}
