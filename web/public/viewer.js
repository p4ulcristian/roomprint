// Viewer: status while processing, then the 3D view, the plan, the video and the files
// of a space, with exports, a measuring tool and a crop box.
import { normalize, fmtM } from "./geom.js";
import { renderBlueprint } from "./blueprint.js";

const token = location.pathname.split("/").filter(Boolean)[1];
const API = `/api/s/${token}`;
const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

// Inside the iOS app (ios/Sources/Roomprint/ViewerView.swift) the page is embedded: the
// app shows the title itself, saves downloads through the share sheet, and hands over
// the owner key of spaces this phone made.
const app = window.roomprintApp ?? null;
if (app || new URLSearchParams(location.search).has("app")) document.body.classList.add("in-app");
const ownerHeaders = () => (app?.ownerKey ? { "x-owner-key": app.ownerKey } : {});

const STATE_TEXT = {
  draft: "Waiting for videos to be uploaded",
  queued: "Queued: waiting for the computer to start",
  processing: "Processing the rooms",
  done: "Done",
  failed: "Processing failed",
};

let space = null, summary = null, view3d = null, tab = null, mode = null, cropBox = null;

async function fetchSummary() {
  summary = await (await fetch(API)).json();
  if (summary.error) throw new Error(summary.error);
  return summary;
}

async function load() {
  await fetchSummary();
  $("title").textContent = summary.meta.name;
  document.title = `${summary.meta.name} · Roomprint`;
  if (!summary.has_space) return showStatus();
  const res = await fetch(`${API}/space.json`);
  if (!res.ok) return showStatus();
  space = normalize(await res.json());
  // A free scan has no rooms: its 3D view is the real scan, and there is no plan to draw.
  const free = !space.rooms.length;
  if (free && !summary.has_mesh) return showStatus("Building the 3D model from the scan");
  $("statusBox").classList.add("hidden");
  $("tabs").classList.remove("hidden");
  $("exportPill").classList.toggle("hidden", !Object.keys(summary.exports).length);
  $("planTab").classList.toggle("hidden", free);
  $("videoTab").classList.toggle("hidden", !videos().length);
  $("pointsChip").classList.toggle("hidden", !summary.has_preview);
  $("modeModel").classList.toggle("hidden", free);
  $("modeScan").classList.toggle("hidden", !summary.has_mesh);
  $("modeSplat").classList.toggle("hidden", summary.splat !== "ready");
  const modes = [...document.querySelectorAll("#tools3d [data-mode]:not(.hidden)")];
  for (const b of [...modes, $("modeSep")]) b.classList.toggle("hidden", modes.length < 2);
  mode ??= free || summary.has_mesh ? "scan" : "model";   // the real scan first, when there is one
  show({ "#plan": free ? "3d" : "plan", "#files": "files", "#video": "video" }[location.hash] ?? "3d");
}

function showStatus(text) {
  const s = summary.status;
  $("dot").className = "dot " + (text ? "processing" : s.state);
  $("stateText").textContent = text ?? STATE_TEXT[s.state] ?? s.state;
  $("stepText").textContent = s.state === "failed" ? s.error || s.step : s.step;
  $("statusBar").classList.toggle("hidden", s.state !== "processing");
  $("statusBar").firstElementChild.style.width = `${Math.round((s.progress || 0) * 100)}%`;
  $("uploadLink").href = `/u/${token}`;
  $("uploadLink").parentElement.classList.toggle("hidden", !!app);
  if (s.state !== "failed") setTimeout(() => load().catch(showError), 5000);
}

function showError(e) {
  $("stateText").textContent = "Could not load: " + e.message;
}

async function show(name) {
  tab = name;
  history.replaceState(null, "", location.search + "#" + name);
  for (const b of document.querySelectorAll("#tabs button")) b.classList.toggle("on", b.dataset.tab === name);
  $("three").classList.toggle("hidden", name !== "3d");
  $("plan").classList.toggle("hidden", name !== "plan");
  $("files").classList.toggle("hidden", name !== "files");
  $("video").classList.toggle("hidden", name !== "video");
  if (name !== "video") $("player").pause();
  $("tools3d").classList.toggle("hidden", name !== "3d");
  $("toolsPlan").classList.toggle("hidden", name !== "plan");
  $("cropPanel").classList.toggle("hidden", name !== "3d" || !$("crop").checked);
  say(null);

  if (name === "plan") {
    view3d?.setActive(false);
    drawPlan();
  } else if (name === "files") {
    view3d?.setActive(false);
    drawFiles();
  } else if (name === "video") {
    view3d?.setActive(false);
    drawVideo();
  } else {
    if (!view3d) {
      try {
        const { create3D } = await import("./view3d.js");
        view3d = create3D($("three"), space, {
          onRoom: showRoomInfo, onMeasure: showMeasure,
          urls: {
            points: `${API}/preview.ply`, mesh: `${API}/mesh.ply`, splat: `${API}/splat.splat`,
            textured: summary.has_textured ? `${API}/textured.glb` : null,
          },
        });
        view3d.setCutaway($("cutaway").checked);
        await setMode(mode);
      } catch (e) {
        $("three").innerHTML = `<div class="statusbox"><div class="card err">The 3D view could not start (${esc(e.message)}).</div></div>`;
        return;
      }
    }
    if (tab === "3d") view3d.setActive(true);
  }
}

// ---------- 3D tools ----------

function say(text) {
  $("info").textContent = text ?? "";
  $("info").classList.toggle("hidden", !text);
}

async function setMode(next) {
  for (const b of document.querySelectorAll("#tools3d [data-mode]")) b.classList.toggle("on", b.dataset.mode === next);
  say(next === "model" ? null : next === "scan" ? "Loading the scan…" : "Loading the splat…");
  try {
    await view3d.setMode(next);
    mode = next;
    say(null);
  } catch (e) {
    say(`Could not load it: ${e.message}`);
    for (const b of document.querySelectorAll("#tools3d [data-mode]")) b.classList.toggle("on", b.dataset.mode === mode);
    return;
  }
  $("cutChip").classList.toggle("hidden", mode !== "model");
  $("cropChip").classList.toggle("hidden", mode !== "scan");
  if (mode !== "scan" && $("crop").checked) { $("crop").checked = false; toggleCrop(); }
  if (mode === "splat" && $("measure").checked) { $("measure").checked = false; toggleMeasure(); }
  $("measure").parentElement.classList.toggle("hidden", mode === "splat");
}

function showRoomInfo(info) {
  say(info ? `${info.room.name || info.room.id} · ${info.area.toFixed(1)} m² · ${fmtM(info.w)} × ${fmtM(info.d)} · tap again to zoom out` : null);
}

function toggleMeasure() {
  const on = $("measure").checked;
  view3d?.setMeasure(on);
  say(on ? "Tap two points to measure between them" : null);
}
function showMeasure(count, half) {
  $("clearBtn").classList.toggle("hidden", !count && !half);
  if ($("measure").checked) say(half ? "Now tap the second point" : "Tap two points to measure between them");
}

// The crop box starts as the whole scan; the sliders move its six faces.
const AXES = ["x", "y", "z"];
function toggleCrop() {
  const on = $("crop").checked;
  $("cropPanel").classList.toggle("hidden", !on);
  if (!on) { cropBox = null; view3d?.setCrop(null); tellApp(); drawExports(); return; }
  const [lo, hi] = view3d.scanBounds();
  AXES.forEach((a, i) => {
    for (const end of [0, 1]) {
      const el = $(`c${a}${end}`);
      Object.assign(el, { min: Math.floor(lo[i] * 20) / 20, max: Math.ceil(hi[i] * 20) / 20, step: 0.05 });
      el.value = end ? el.max : el.min;
    }
  });
  readCrop();
}
function readCrop(moved) {
  const v = [];
  AXES.forEach(a => {
    const lo = $(`c${a}0`), hi = $(`c${a}1`);
    // the two ends never cross: the one being dragged stops 10 cm short of the other
    if (+hi.value - +lo.value < 0.1) (moved === hi ? hi : lo).value = moved === hi ? +lo.value + 0.1 : +hi.value - 0.1;
    $(`c${a}o`).textContent = `${(+hi.value - +lo.value).toFixed(2)} m`;
    v.push(+lo.value, +hi.value);
  });
  cropBox = [v[0], v[2], v[4], v[1], v[3], v[5]];
  view3d.setCrop(cropBox);
  tellApp();
  drawExports();
}
const cropQuery = () => (cropBox ? `?crop=${cropBox.map(x => x.toFixed(2)).join(",")}` : "");
const tellApp = () => window.webkit?.messageHandlers?.roomprint?.postMessage({ crop: cropBox });

// ---------- exports ----------

const KINDS = [
  ["mesh", "Real scan", "The scanned rooms as a 3D mesh", { glb: "GLB", obj: "OBJ", usdz: "USDZ · AR", stl: "STL", ply: "PLY" }],
  ["points", "Point cloud", "Coloured points on the scan's surfaces", { ply: "PLY", las: "LAS", xyz: "XYZ" }],
  ["plan", "Floor plan", "Walls, doors, windows and measurements", { pdf: "PDF · 1:50", svg: "SVG", png: "PNG", dxf: "DXF · CAD" }],
  ["model", "Drawn model", "The clean 3D model made from the floor plan", { glb: "GLB", obj: "OBJ", usdz: "USDZ · AR", stl: "STL" }],
  ["splat", "Gaussian splat", "The scan as a splat, for splat viewers", { ply: "PLY" }],
  ["raw", "Raw capture", "Photos, depth and camera poses (nerfstudio layout)", { zip: "ZIP" }],
];

function drawExports() {
  if (!summary || $("exportSheet").classList.contains("hidden")) return;
  const parts = [];
  for (const [kind, title, what, labels] of KINDS) {
    const formats = summary.exports[kind];
    if (!formats) continue;
    const crop = cropBox && (kind === "mesh" || kind === "points") ? cropQuery() : "";
    parts.push(`<h3>${title}${crop ? " · cropped" : ""}</h3><p class="muted small">${what}</p><div class="formats">` +
      formats.map(f => `<a href="${API}/export/${kind}.${f}${crop}" download>${labels[f] ?? f.toUpperCase()}</a>`).join("") + `</div>`);
  }
  // A splat is trained on request: it holds the GPU for some minutes.
  const canAsk = summary.has_mesh && (!summary.owned || app?.ownerKey);
  if (summary.splat === "asked") parts.push(`<h3>Gaussian splat</h3><p class="muted small">Asked for. It is trained when the computer's graphics card is free, and takes several minutes.</p>`);
  else if (summary.splat !== "ready" && canAsk)
    parts.push(`<h3>Gaussian splat</h3><p class="muted small">${summary.splat === "failed" ? "The last try failed. " : ""}A photo-real view of the scan to look around in, trained from its photos in several minutes. It comes out best from a slow walk that shows everything from more than one side.</p>
      <div class="formats"><button id="askSplat">Make a splat</button></div>`);
  $("exportList").innerHTML = parts.join("");
  for (const a of $("exportList").querySelectorAll("a")) a.onclick = () => {
    a.classList.add("busy");
    setTimeout(() => a.classList.remove("busy"), 6000);
  };
  if ($("askSplat")) $("askSplat").onclick = async () => {
    $("askSplat").disabled = true;
    const res = await fetch(`${API}/splat`, { method: "POST", headers: ownerHeaders() });
    const out = await res.json().catch(() => ({}));
    if (res.ok) summary = out; else alert(out.error || "Could not ask for the splat.");
    drawExports();
  };
}

function toggleExports(open) {
  $("exportSheet").classList.toggle("hidden", !open);
  if (open) fetchSummary().then(drawExports).catch(() => {});
  drawExports();
}

// ---------- video, files, plan ----------

const VIDEO = /\.(mov|mp4|m4v|webm|3gp|mkv)$/i;
const videos = () => [...summary.clips].reverse().filter(c => VIDEO.test(c.filename));
let playing = null;

// The walkthrough video, newest first; with several, a strip to pick one.
function drawVideo(id) {
  const list = videos();
  if (!list.length) return;
  const pick = list.find(c => c.id === (id ?? playing)) ?? list[0];
  // /play is a copy every browser can show; the first time it is asked for, it is still being made
  const src = `${API}/clips/${pick.id}/play`;
  if (playing !== pick.id) {
    const v = $("player");
    $("vwait").classList.remove("hidden");
    v.onloadeddata = v.onerror = () => $("vwait").classList.add("hidden");
    v.src = src;
    playing = pick.id;
  }
  const strip = $("vlist");
  strip.classList.toggle("hidden", list.length < 2);
  strip.innerHTML = list.map((c, i) =>
    `<button class="chip${c.id === pick.id ? " on" : ""}" data-id="${c.id}">${c.room_name ? esc(c.room_name) : `Video ${list.length - i}`}</button>`).join("");
  for (const b of strip.querySelectorAll("button")) b.onclick = () => drawVideo(b.dataset.id);
}

// Everything uploaded to this space: videos open in the Video tab, a scan's USDZ opens
// in AR Quick Look on an iPhone (rel="ar" needs an <img> child), the rest downloads.
function drawFiles() {
  const box = $("files");
  const size = b => b > 1e6 ? `${(b / 1e6).toFixed(1)} MB` : `${Math.max(1, Math.round(b / 1e3))} kB`;
  const when = t => new Date(t).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  const items = [...summary.clips].reverse().map(c => {
    const url = `${API}/clips/${c.id}/file`;
    const head = `<div class="fhead"><strong>${esc(c.room_name || c.filename)}</strong><span class="muted small">${size(c.bytes)} · ${when(c.uploaded)}</span></div>`;
    if (VIDEO.test(c.filename))
      return `<section class="card">${head}<p class="muted small">Video with sound</p>
        <button class="btn" data-play="${c.id}">Play</button> <a class="btn secondary" href="${url}" download="${esc(c.filename)}">Download</a></section>`;
    if (/\.usdz$/i.test(c.filename))
      return `<section class="card">${head}<p class="muted small">The scanned 3D model. On an iPhone it opens in AR, at real size in your room.</p>
        <a rel="ar" class="btn secondary" href="${url}"><img alt="" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" width="1" height="1">Open the 3D model</a></section>`;
    const what = /\.roomplan$/i.test(c.filename) ? "LiDAR scan data (JSON)"
      : /\.freescan$/i.test(c.filename) ? "A free scan's note (JSON)"
      : /\.rgbd$/i.test(c.filename) ? "Depth measurements and small photos from the scan; the Real scan 3D model is made from them"
      : /\.poses$/i.test(c.filename) ? "Where the camera was for every frame of the video; the Real scan's photo texture is made with it"
      : "Uploaded file";
    return `<section class="card">${head}<p class="muted small">${what}</p><a class="btn secondary" href="${url}" download="${esc(c.filename)}">Download</a></section>`;
  });
  const note = `<section class="card notice"><p class="small"><strong>Who can see this:</strong> everyone who has this
    page's link can see the floor plan, the 3D views and the video, and download these files and the exports made
    from them. They are stored on the Roomprint server. The phone that made this space can delete any file, or the
    whole space, in the Roomprint app: it is deleted from the server right away, for good. <a href="/privacy">Privacy</a></p></section>`;
  box.innerHTML = `<div class="wrap">${note}${items.join("") || '<p class="muted">Nothing uploaded yet.</p>'}</div>`;
  for (const b of box.querySelectorAll("[data-play]")) b.onclick = () => { show("video"); drawVideo(b.dataset.play); };
}

function drawPlan() {
  $("plan").innerHTML = renderBlueprint(space, { furniture: $("furn").checked });
}

for (const b of document.querySelectorAll("#tabs button")) b.onclick = () => show(b.dataset.tab);
for (const b of document.querySelectorAll("#tools3d [data-mode]")) b.onclick = () => view3d && setMode(b.dataset.mode);
$("cutaway").onchange = () => view3d?.setCutaway($("cutaway").checked);
$("resetBtn").onclick = () => view3d?.reset();
$("measure").onchange = toggleMeasure;
$("clearBtn").onclick = () => view3d?.clearMeasures();
$("crop").onchange = toggleCrop;
for (const el of document.querySelectorAll("#cropPanel input")) el.oninput = () => readCrop(el);
$("points").onchange = async () => {
  const cb = $("points");
  cb.disabled = true;
  try { await view3d?.setPoints(cb.checked); }
  catch (e) { cb.checked = false; say("Could not load the point cloud: " + e.message); }
  finally { cb.disabled = false; }
};
$("furn").onchange = drawPlan;
$("printBtn").onclick = () => print();
$("exportBtn").onclick = () => toggleExports($("exportSheet").classList.contains("hidden"));
$("exportClose").onclick = () => toggleExports(false);
addEventListener("beforeprint", () => { if (space?.rooms.length && tab !== "plan") { drawPlan(); $("plan").classList.remove("hidden"); } });
addEventListener("afterprint", () => { if (tab !== "plan") $("plan").classList.add("hidden"); });

load().catch(showError);
