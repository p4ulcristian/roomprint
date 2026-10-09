// Data dir layout shared by the server and admin CLI. This is the contract
// with the Python worker (see the README section in server.ts):
//   spaces/<id>/meta.json, uploads/<clip>.<ext> + <clip>.json, status.json,
//   space.json, preview.ply
// Unfinished uploads live in spaces/<id>/incoming/ and only move to uploads/
// once every byte has arrived, so the worker never sees a partial file.
import { join } from "path";
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, readdirSync, rmSync } from "fs";
import { randomBytes, createHash } from "crypto";

export const DATA_DIR = process.env.DATA_DIR ?? "data";
export const SPACES = join(DATA_DIR, "spaces");

export type Meta = {
  id: string;
  name: string;
  token: string;
  created: string;
  scale: { wall_length_m: number | null; note: string };
  capture: "walkthrough" | "per-room";
  // sha256 of the owner key: whoever holds the key (the phone that made the space) may
  // delete it. The view link alone only lets people look.
  owner_hash?: string;
};
export type State = "draft" | "queued" | "processing" | "done" | "failed";
export type Status = { state: State; step: string; progress: number; error: string | null; updated: string };
export type Clip = { id: string; room_name: string | null; filename: string; bytes: number; uploaded: string };
// chunks: the [offset, length] pieces written so far. They may arrive in any order (the iOS
// app's background uploads); older pending files without it were written front to back.
export type Pending = {
  id: string; room_name: string | null; filename: string; bytes: number; ext: string; started: string;
  chunks?: [number, number][];
};

export const now = () => new Date().toISOString();
export const spaceDir = (id: string) => join(SPACES, id);

export function readJson<T>(path: string): T | null {
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return null; }
}
export function writeJson(path: string, data: unknown) {
  writeFileSync(path + ".tmp", JSON.stringify(data, null, 2));
  renameSync(path + ".tmp", path);
}

export function listSpaces(): Meta[] {
  if (!existsSync(SPACES)) return [];
  return readdirSync(SPACES)
    .map(id => readJson<Meta>(join(SPACES, id, "meta.json")))
    .filter((m): m is Meta => !!m)
    .sort((a, b) => a.created.localeCompare(b.created));
}

export function byToken(token: string): Meta | null {
  if (!/^[A-Za-z0-9_-]{8,64}$/.test(token)) return null;
  return listSpaces().find(m => m.token === token) ?? null;
}

// Deleting a space removes every file of it at once, for good: there is no trash and
// no backup. Its links stop working immediately.
export function deleteSpace(id: string) {
  rmSync(spaceDir(id), { recursive: true, force: true });
}

export const hashKey = (key: string) => createHash("sha256").update(key).digest("hex");

/** A new owner key for the space; only its hash is stored. */
export function setOwner(meta: Meta): string {
  const key = randomBytes(24).toString("base64url");
  meta.owner_hash = hashKey(key);
  writeJson(join(spaceDir(meta.id), "meta.json"), meta);
  return key;
}

export function createSpace(name: string): Meta {
  const id = "sp_" + randomBytes(4).toString("hex");
  const meta: Meta = {
    id, name,
    token: randomBytes(18).toString("base64url"),
    created: now(),
    scale: { wall_length_m: null, note: "" },
    capture: "walkthrough",
  };
  const dir = spaceDir(id);
  mkdirSync(join(dir, "uploads"), { recursive: true });
  mkdirSync(join(dir, "incoming"), { recursive: true });
  writeJson(join(dir, "meta.json"), meta);
  setStatus(id, { state: "draft", step: "waiting for uploads", progress: 0, error: null });
  return meta;
}

export function getStatus(id: string): Status {
  return readJson<Status>(join(spaceDir(id), "status.json"))
    ?? { state: "draft", step: "waiting for uploads", progress: 0, error: null, updated: now() };
}
export function setStatus(id: string, s: Omit<Status, "updated">) {
  writeJson(join(spaceDir(id), "status.json"), { ...s, updated: now() });
}

export function listClips(id: string): Clip[] {
  const dir = join(spaceDir(id), "uploads");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter(f => f.endsWith(".json"))
    .map(f => readJson<Clip>(join(dir, f)))
    .filter((c): c is Clip => !!c)
    .sort((a, b) => a.uploaded.localeCompare(b.uploaded));
}

export function listPending(id: string): Pending[] {
  const dir = join(spaceDir(id), "incoming");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter(f => f.endsWith(".json"))
    .map(f => readJson<Pending>(join(dir, f)))
    .filter((p): p is Pending => !!p);
}
