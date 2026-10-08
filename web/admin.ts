// Roomprint admin CLI.
//   bun web/admin.ts invite "Grandma's flat"   new space + upload link
//   bun web/admin.ts list                      all spaces with state and links
//   bun web/admin.ts sample                    space with the fixture as space.json (state done)
// Set BASE_URL (e.g. https://roomprint.example.com) to print full links.
import { join } from "path";
import { copyFileSync, readFileSync } from "fs";
import { createSpace, listSpaces, getStatus, listClips, setStatus, spaceDir, writeJson, DATA_DIR } from "./store";

const BASE = (process.env.BASE_URL ?? "").replace(/\/$/, "");
const [cmd, ...args] = process.argv.slice(2);

function links(token: string) {
  return `upload ${BASE}/u/${token}\n  viewer ${BASE}/s/${token}`;
}

if (cmd === "invite") {
  const name = args.join(" ").trim();
  if (!name) { console.error('usage: bun web/admin.ts invite "Space name"'); process.exit(1); }
  const meta = createSpace(name);
  console.log(`${meta.id}  ${meta.name}\n  ${links(meta.token)}`);
} else if (cmd === "list") {
  const spaces = listSpaces();
  if (!spaces.length) console.log(`no spaces in ${DATA_DIR}`);
  for (const m of spaces) {
    const s = getStatus(m.id);
    const clips = listClips(m.id).length;
    console.log(`${m.id}  ${m.name}  [${s.state}${s.step ? ": " + s.step : ""}]  ${clips} clip(s)  ${m.created.slice(0, 10)}`);
    console.log(`  ${links(m.token)}`);
  }
} else if (cmd === "sample") {
  const fixture = join(import.meta.dir, "fixtures", "sample-space.json");
  const space = JSON.parse(readFileSync(fixture, "utf8"));
  const meta = createSpace(args.join(" ").trim() || space.name || "Sample flat");
  meta.scale = { wall_length_m: 8, note: "sample fixture" };
  writeJson(join(spaceDir(meta.id), "meta.json"), meta);
  copyFileSync(fixture, join(spaceDir(meta.id), "space.json"));
  setStatus(meta.id, { state: "done", step: "sample fixture", progress: 1, error: null });
  console.log(`${meta.id}  ${meta.name} (sample)\n  ${links(meta.token)}`);
} else {
  console.log(readFileSync(import.meta.path, "utf8").split("\n").slice(0, 5).join("\n"));
  process.exit(cmd ? 1 : 0);
}
