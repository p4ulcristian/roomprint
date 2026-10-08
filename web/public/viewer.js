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
  show(location.hash === "#plan" ? "plan" : "3d");
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
  history.replaceState(null, "", name === "plan" ? "#plan" : "#3d");
  for (const b of document.querySelectorAll("#tabs button")) b.classList.toggle("on", b.dataset.tab === name);
  $("three").classList.toggle("hidden", name !== "3d");
  $("plan").classList.toggle("hidden", name !== "plan");
  $("tools3d").classList.toggle("hidden", name !== "3d");
  $("toolsPlan").classList.toggle("hidden", name !== "plan");
  $("info").classList.add("hidden");

  if (name === "plan") {
    view3d?.setActive(false);
    drawPlan();
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
