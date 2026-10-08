// Viewer: status while processing, then 3D and Blueprint tabs over space.json.
import { normalize, fmtM } from "./geom.js";
import { renderBlueprint, downloadSvg } from "./blueprint.js";

const token = location.pathname.split("/").filter(Boolean)[1];
const API = `/api/s/${token}`;
const $ = id => document.getElementById(id);

const STATE_TEXT = {
  draft: "Waiting for videos to be uploaded",
  queued: "Queued: waiting for the computer to start",
  processing: "Processing the rooms",
  done: "Done",
  failed: "Processing failed",
};

let space = null, summary = null, view3d = null, tab = null, svgText = "";

async function load() {
  summary = await (await fetch(API)).json();
  if (summary.error) throw new Error(summary.error);
  $("title").textContent = summary.meta.name;
  document.title = `${summary.meta.name} · Roomprint`;
  if (!summary.has_space) return showStatus();
  const res = await fetch(`${API}/space.json`);
  if (!res.ok) return showStatus();
  space = normalize(await res.json());
  $("statusBox").classList.add("hidden");
  $("tabs").classList.remove("hidden");
  $("pointsChip").classList.toggle("hidden", !summary.has_preview);
  show({ "#plan": "plan", "#files": "files" }[location.hash] ?? "3d");
}

function showStatus() {
  const s = summary.status;
  $("dot").className = "dot " + s.state;
  $("stateText").textContent = STATE_TEXT[s.state] ?? s.state;
  $("stepText").textContent = s.state === "failed" ? s.error || s.step : s.step;
  $("statusBar").classList.toggle("hidden", s.state !== "processing");
  $("statusBar").firstElementChild.style.width = `${Math.round((s.progress || 0) * 100)}%`;
  $("uploadLink").href = `/u/${token}`;
  if (s.state !== "failed") setTimeout(() => load().catch(showError), 5000);
}

function showError(e) {
  $("stateText").textContent = "Could not load: " + e.message;
}

async function show(name) {
  tab = name;
  history.replaceState(null, "", "#" + name);
  for (const b of document.querySelectorAll("#tabs button")) b.classList.toggle("on", b.dataset.tab === name);
  $("three").classList.toggle("hidden", name !== "3d");
  $("plan").classList.toggle("hidden", name !== "plan");
  $("files").classList.toggle("hidden", name !== "files");
  $("tools3d").classList.toggle("hidden", name !== "3d");
  $("toolsPlan").classList.toggle("hidden", name !== "plan");
  $("info").classList.add("hidden");

  if (name === "plan") {
    view3d?.setActive(false);
    drawPlan();
  } else if (name === "files") {
    view3d?.setActive(false);
    drawFiles();
  } else {
    if (!view3d) {
      try {
        const { create3D } = await import("./view3d.js");
        view3d = create3D($("three"), space, { onRoom: showRoomInfo, pointsUrl: `${API}/preview.ply` });
        view3d.setCutaway($("cutaway").checked);
      } catch (e) {
        $("three").innerHTML = `<div class="statusbox"><div class="card err">The 3D view could not start (${e.message}). The Blueprint tab still works.</div></div>`;
        return;
      }
    }
    if (tab === "3d") view3d.setActive(true);
  }
}

// Everything uploaded to this space: videos play here, a scan's USDZ opens in AR
// Quick Look on an iPhone (rel="ar" needs an <img> child), the rest downloads.
const VIDEO = /\.(mov|mp4|m4v|webm|3gp|mkv)$/i;
function drawFiles() {
  const box = $("files");
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const size = b => b > 1e6 ? `${(b / 1e6).toFixed(1)} MB` : `${Math.max(1, Math.round(b / 1e3))} kB`;
  const when = t => new Date(t).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  const items = [...summary.clips].reverse().map(c => {
    const url = `${API}/clips/${c.id}/file`;
    const head = `<div class="fhead"><strong>${esc(c.room_name || c.filename)}</strong><span class="muted small">${size(c.bytes)} · ${when(c.uploaded)}</span></div>`;
    if (VIDEO.test(c.filename))
      return `<section class="card">${head}<video controls playsinline preload="metadata" src="${url}"></video></section>`;
    if (/\.usdz$/i.test(c.filename))
      return `<section class="card">${head}<p class="muted small">The scanned 3D model. On an iPhone it opens in AR, at real size in your room.</p>
        <a rel="ar" class="btn secondary" href="${url}"><img alt="" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" width="1" height="1">Open the 3D model</a></section>`;
    const what = /\.roomplan$/i.test(c.filename) ? "LiDAR scan data (JSON)" : "Uploaded file";
    return `<section class="card">${head}<p class="muted small">${what}</p><a class="btn secondary" href="${url}" download="${esc(c.filename)}">Download</a></section>`;
  });
  box.innerHTML = `<div class="wrap">${items.join("") || '<p class="muted">Nothing uploaded yet.</p>'}</div>`;
}

function showRoomInfo(info) {
  const box = $("info");
  if (!info) { box.classList.add("hidden"); return; }
  box.textContent = `${info.room.name || info.room.id} · ${info.area.toFixed(1)} m² · ${fmtM(info.w)} × ${fmtM(info.d)} · tap again to zoom out`;
  box.classList.remove("hidden");
}

function drawPlan() {
  svgText = renderBlueprint(space, { furniture: $("furn").checked });
  $("plan").innerHTML = svgText;
}

for (const b of document.querySelectorAll("#tabs button")) b.onclick = () => show(b.dataset.tab);
$("cutaway").onchange = () => view3d?.setCutaway($("cutaway").checked);
$("resetBtn").onclick = () => view3d?.reset();
$("points").onchange = async () => {
  const cb = $("points");
  cb.disabled = true;
  try { await view3d?.setPoints(cb.checked); }
  catch (e) { cb.checked = false; alert("Could not load the point cloud: " + e.message); }
  finally { cb.disabled = false; }
};
$("furn").onchange = drawPlan;
$("printBtn").onclick = () => { if (tab !== "plan") show("plan"); setTimeout(() => print(), 50); };
$("svgBtn").onclick = () => downloadSvg(svgText, space?.name);
addEventListener("beforeprint", () => { if (space && tab !== "plan") { drawPlan(); $("plan").classList.remove("hidden"); } });
addEventListener("afterprint", () => { if (tab !== "plan") $("plan").classList.add("hidden"); });

load().catch(showError);
