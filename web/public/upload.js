// Upload page: capture choice, scale, chunked resumable uploads, status polling.
const token = location.pathname.split("/").filter(Boolean)[1];
const API = `/api/s/${token}`;
const CHUNK = 8 * 1024 * 1024;
const $ = id => document.getElementById(id);

let summary = null;
const local = new Map();   // clip id -> { file, received, bytes, state, msg, filename, room_name, speed }
const queue = [];          // clip ids waiting for their turn
let running = false;
let pollTimer = null;
let wakeLock = null;

const fmtBytes = b => b >= 1e9 ? (b / 1e9).toFixed(2) + " GB" : b >= 1e6 ? (b / 1e6).toFixed(1) + " MB" : Math.max(1, Math.round(b / 1e3)) + " kB";
const fmtTime = s => s > 90 ? Math.round(s / 60) + " min" : Math.max(1, Math.round(s)) + " s";
const sleep = ms => new Promise(r => setTimeout(r, ms));
const locked = () => ["queued", "processing"].includes(summary?.status.state);

async function api(path, opts = {}) {
  const res = await fetch(API + path, opts);
  const data = await res.json().catch(() => ({}));
  if (!res.ok && res.status !== 409) throw Object.assign(new Error(data.error || res.statusText), { status: res.status });
  return { status: res.status, data };
}

async function refresh() {
  const { data } = await api("");
  summary = data;
  render();
  schedulePoll();
}

function schedulePoll() {
  clearTimeout(pollTimer);
  if (locked()) pollTimer = setTimeout(() => refresh().catch(() => schedulePoll()), 4000);
}

// ---------- rendering ----------

const STATE_TEXT = {
  draft: "Waiting for your videos",
  queued: "Queued: waiting for the computer to start",
  processing: "Processing your rooms",
  done: "Done! Your floor plan is ready",
  failed: "Processing failed",
};

function renderStatus() {
  const s = summary.status;
  $("title").textContent = summary.meta.name;
  document.title = `${summary.meta.name} · Roomprint`;
  $("dot").className = "dot " + s.state;
  $("stateText").textContent = STATE_TEXT[s.state] ?? s.state;
  $("stepText").textContent = s.state === "failed" ? (s.error || s.step || "") + " You can add videos and send again." : s.step || "";
  const showBar = s.state === "processing";
  $("statusBar").classList.toggle("hidden", !showBar);
  $("statusBar").firstElementChild.style.width = `${Math.round((s.progress || 0) * 100)}%`;
  const link = $("viewLink");
  link.classList.toggle("hidden", !summary.has_space);
  link.querySelector("a").href = `/s/${token}`;
  $("editor").classList.toggle("hidden", locked());
}

function renderSettings() {
  const m = summary.meta;
  for (const r of document.querySelectorAll("input[name=capture]")) r.checked = r.value === m.capture;
  $("pickWalk").classList.toggle("hidden", m.capture !== "walkthrough");
  $("pickRoom").classList.toggle("hidden", m.capture !== "per-room");
  if (document.activeElement !== $("wallLen")) $("wallLen").value = m.scale.wall_length_m ?? "";
  if (document.activeElement !== $("note")) $("note").value = m.scale.note ?? "";
}

function clipRows() {
  const rows = new Map();
  for (const c of summary.clips) rows.set(c.id, { ...c, received: c.bytes, state: "done" });
  for (const p of summary.pending) rows.set(p.id, { ...p, state: "paused" });
  for (const [id, u] of local) rows.set(id, { ...rows.get(id), ...u, id });
  return [...rows.values()];
}

function renderClips() {
  const box = $("clips");
  const rows = clipRows();
  box.innerHTML = "";
  for (const r of rows) {
    const div = document.createElement("div");
    div.className = "clip " + r.state;
    const pct = r.bytes ? (r.received / r.bytes) * 100 : 0;
    let line;
    if (r.state === "done") line = `Uploaded · ${fmtBytes(r.bytes)}`;
    else if (r.state === "paused") line = `Paused at ${Math.floor(pct)}% · pick the same file again to continue`;
    else if (r.state === "waiting") line = `Waiting · ${fmtBytes(r.bytes)}`;
    else if (r.state === "error") line = r.msg || "Error";
    else {
      const left = r.speed ? fmtTime((r.bytes - r.received) / r.speed) + " left" : "";
      line = `${Math.floor(pct)}% of ${fmtBytes(r.bytes)}${r.speed ? ` · ${fmtBytes(r.speed)}/s · ${left}` : ""}${r.msg ? " · " + r.msg : ""}`;
    }
    div.innerHTML = `<div class="top"><span class="name"></span><button class="link">Remove</button></div>
      <div class="muted small room"></div><div class="bar"><i style="width:${pct}%"></i></div><div class="muted small line"></div>`;
    div.querySelector(".name").textContent = r.filename;
    div.querySelector(".room").textContent = r.room_name ? `Room: ${r.room_name}` : "";
    div.querySelector(".line").textContent = line;
    div.querySelector("button").onclick = () => removeClip(r.id);
    box.appendChild(div);
  }
  if (!rows.length) box.innerHTML = `<p class="muted small">No videos yet.</p>`;
  renderSubmit(rows);
}

function renderSubmit(rows = clipRows()) {
  const done = rows.filter(r => r.state === "done").length;
  const busy = rows.length - done;
  const btn = $("submitBtn");
  btn.disabled = !done || busy > 0 || locked();
  btn.textContent = summary.status.state === "done" || summary.status.state === "failed" ? "Send again for processing" : "Send for processing";
  $("submitHint").textContent = !done ? "Upload at least one video first."
    : busy ? "Wait until all uploads have finished."
    : `${done} file${done > 1 ? "s" : ""} ready.${summary.meta.scale.wall_length_m ? "" : " Tip: add the wall length above for accurate sizes."}`;
}

function render() {
  renderStatus();
  renderSettings();
  renderClips();
}

// ---------- settings ----------

let saveTimer = null;
function saveMeta(body) {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async () => {
    try {
      const { data, status } = await api("/meta", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
      if (status === 409) throw new Error(data.error);
      summary = data;
      $("savedNote").textContent = "Saved.";
      renderSettings(); renderSubmit();
    } catch (e) {
      $("savedNote").textContent = e.message;
    }
  }, 500);
}
for (const r of document.querySelectorAll("input[name=capture]")) {
  r.onchange = () => { summary.meta.capture = r.value; renderSettings(); saveMeta({ capture: r.value }); };
}
$("wallLen").oninput = () => {
  const v = $("wallLen").value.replace(",", ".");
  if (v === "" || Number(v) > 0.3) saveMeta({ wall_length_m: v === "" ? null : Number(v) });
};
$("note").oninput = () => saveMeta({ note: $("note").value });

// ---------- picking files ----------

let pickRoom = null;
$("pickBtn").onclick = () => { pickRoom = null; $("file").click(); };
$("pickRoomBtn").onclick = () => {
  const name = $("roomName").value.trim();
  if (!name) { $("roomName").focus(); $("roomName").placeholder = "Type the room name first"; return; }
  pickRoom = name;
  $("file").click();
};
$("file").onchange = async () => {
  const files = [...$("file").files];
  $("file").value = "";
  for (const f of files) await addFile(f, pickRoom);
  if (pickRoom) $("roomName").value = "";
};

async function addFile(file, room_name) {
  try {
    const { data, status } = await api("/clips", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ filename: file.name, bytes: file.size, room_name }),
    });
    if (status === 409) throw new Error(data.error);
    const prev = summary.pending.find(p => p.id === data.id);
    local.set(data.id, {
      file, filename: file.name, bytes: file.size, received: data.received,
      room_name: room_name ?? prev?.room_name ?? null, state: "waiting", msg: "",
    });
    queue.push(data.id);
    renderClips();
    pump();
  } catch (e) {
    alert(`${file.name}: ${e.message}`);
  }
}

async function removeClip(id) {
  const u = local.get(id);
  if (u && u.state === "uploading" && !confirm("Stop this upload and remove it?")) return;
  if (u) u.cancelled = true;
  local.delete(id);
  try { await api(`/clips/${id}`, { method: "DELETE" }); } catch {}
  await refresh();
}

// ---------- chunked upload ----------

async function pump() {
  if (running) return;
  running = true;
  await holdWake(true);
  try {
    while (queue.length) {
      const id = queue.shift();
      const u = local.get(id);
      if (u && !u.cancelled) await upload(id, u);
    }
  } finally {
    running = false;
    await holdWake(false);
    await refresh().catch(() => {});
  }
}

async function upload(id, u) {
  u.state = "uploading";
  let failures = 0;
  let t0 = performance.now(), b0 = u.received;
  while (u.received < u.bytes && !u.cancelled) {
    const end = Math.min(u.received + CHUNK, u.bytes);
    try {
      const res = await fetch(`${API}/clips/${id}?offset=${u.received}`, {
        method: "PUT", headers: { "content-type": "application/octet-stream" }, body: u.file.slice(u.received, end),
      });
      const data = await res.json().catch(() => ({}));
      if (res.status === 409 && typeof data.received === "number") { u.received = data.received; continue; }
      if (!res.ok) throw Object.assign(new Error(data.error || `HTTP ${res.status}`), { fatal: res.status < 500 && res.status !== 408 && res.status !== 429 });
      if (data.complete) { u.received = u.bytes; break; }
      u.received = data.received;
      failures = 0;
      u.msg = "";
      const dt = (performance.now() - t0) / 1000;
      if (dt > 2) { u.speed = (u.received - b0) / dt; if (dt > 20) { t0 = performance.now(); b0 = u.received; } }
    } catch (e) {
      if (e.fatal) { u.state = "error"; u.msg = e.message; renderClips(); return; }
      failures++;
      const wait = Math.min(30, 2 ** Math.min(failures, 5));
      u.msg = `connection lost, retrying in ${wait} s`;
      renderClips();
      await Promise.race([sleep(wait * 1000), new Promise(r => addEventListener("online", r, { once: true }))]);
      // Re-sync with what the server actually has before continuing.
      try { const info = await (await fetch(`${API}/clips/${id}`)).json(); if (typeof info.received === "number") u.received = info.received; } catch {}
    }
    renderClips();
  }
  if (!u.cancelled) { u.state = "done"; u.msg = ""; u.file = null; }
  renderClips();
}

async function holdWake(on) {
  try {
    if (on && "wakeLock" in navigator && !wakeLock) wakeLock = await navigator.wakeLock.request("screen");
    if (!on && wakeLock) { await wakeLock.release(); wakeLock = null; }
  } catch {}
}
document.addEventListener("visibilitychange", () => { if (running && document.visibilityState === "visible") { wakeLock = null; holdWake(true); } });
addEventListener("beforeunload", e => { if (running) { e.preventDefault(); e.returnValue = ""; } });

// ---------- submit ----------

$("submitBtn").onclick = async () => {
  $("submitErr").textContent = "";
  if (!summary.meta.scale.wall_length_m && !summary.meta.scale.note &&
      !confirm("No wall length given, so sizes will be estimated and may be off. Send anyway?")) return;
  try {
    const { data, status } = await api("/submit", { method: "POST" });
    if (status === 409) throw new Error(data.error);
    summary = data;
    render();
    schedulePoll();
    scrollTo({ top: 0, behavior: "smooth" });
  } catch (e) {
    $("submitErr").textContent = e.message;
  }
};

refresh().catch(e => { $("stateText").textContent = "This link does not work: " + e.message; });
