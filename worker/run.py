"""Roomprint worker.

  python run.py watch              process queued spaces forever (one at a time)
  python run.py process <space_id> process one space now, whatever its state
  python run.py mesh <space_id>    fuse the space's newest LiDAR depth file again
  python run.py texture <space_id> paint the fused mesh from the photos again
  python run.py splat <space_id>   train the space's Gaussian splat now

Reads/writes DATA_DIR/spaces/<id>/ (contract in web/store.ts). The model is loaded
per job and freed afterwards so the GPU is only held while a job runs. A job only
starts when enough VRAM is free (the GPU is shared with gaming and other daemons).
"""
import gc
import json
import os
import shutil
import subprocess
import sys
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

DATA_DIR = Path(os.environ.get("DATA_DIR", "data"))
SPACES = DATA_DIR / "spaces"
NEED_VRAM_MB = int(os.environ.get("NEED_VRAM_MB", "10000"))
SPLAT_VRAM_MB = int(os.environ.get("SPLAT_VRAM_MB", "3000"))   # the trainer peaks near 1.5 GB
VIDEO_EXT = {".mov", ".mp4", ".m4v", ".webm", ".mkv", ".avi"}


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def read_json(p: Path):
    try:
        return json.loads(p.read_text())
    except Exception:
        return None


def write_json(p: Path, data):
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    tmp.replace(p)


def set_status(d: Path, state, step, progress, error=None):
    write_json(d / "status.json", {"state": state, "step": step, "progress": round(progress, 3),
                                   "error": error, "updated": now()})
    print(f"[{d.name}] {state} {progress:.0%} {step}" + (f" ERROR {error}" if error else ""), flush=True)


def free_vram_mb() -> int:
    out = subprocess.run(["nvidia-smi", "--query-gpu=memory.free", "--format=csv,noheader,nounits"],
                         capture_output=True, text=True).stdout
    return int(out.split()[0])


def write_ply(path: Path, pts: np.ndarray, cols: np.ndarray, max_pts=600_000, voxel=0.02):
    q = np.floor(pts / voxel).astype(np.int64)
    _, idx = np.unique(q, axis=0, return_index=True)
    if len(idx) > max_pts:
        idx = np.random.default_rng(0).choice(idx, max_pts, replace=False)
    pts, cols = pts[idx].astype("<f4"), cols[idx].astype(np.uint8)
    rec = np.empty(len(pts), dtype=[("x", "<f4"), ("y", "<f4"), ("z", "<f4"),
                                    ("red", "u1"), ("green", "u1"), ("blue", "u1")])
    rec["x"], rec["y"], rec["z"] = pts.T
    rec["red"], rec["green"], rec["blue"] = cols.T
    header = ("ply\nformat binary_little_endian 1.0\n"
              f"element vertex {len(rec)}\n"
              "property float x\nproperty float y\nproperty float z\n"
              "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n")
    tmp = path.with_suffix(".tmp")
    with open(tmp, "wb") as f:
        f.write(header.encode())
        f.write(rec.tobytes())
    tmp.replace(path)


def offset_space(space: dict, dx: float):
    """Shift a per-room result along x so separately filmed rooms sit side by side."""
    for r in space["rooms"]:
        r["polygon"] = [[x + dx, y] for x, y in r["polygon"]]
    for w in space["walls"]:
        w["a"][0] += dx
        w["b"][0] += dx
    for o in space["objects"]:
        o["center"][0] += dx


def merge_spaces(parts: list[dict]) -> dict:
    out = {"version": 1, "rooms": [], "walls": [], "openings": [], "objects": [], "scale": parts[0]["scale"]}
    x = 0.0
    for pi, sp in enumerate(parts):
        pre = f"c{pi + 1}"
        xs = [p[0] for r in sp["rooms"] for p in r["polygon"]] or [0]
        offset_space(sp, x - min(xs))
        x += (max(xs) - min(xs)) + 1.0
        ren = {r["id"]: f"{pre}{r['id']}" for r in sp["rooms"]}
        wren = {w["id"]: f"{pre}{w['id']}" for w in sp["walls"]}
        for r in sp["rooms"]:
            out["rooms"].append(dict(r, id=ren[r["id"]]))
        for w in sp["walls"]:
            out["walls"].append(dict(w, id=wren[w["id"]], rooms=[ren[r] for r in w["rooms"]]))
        for o in sp["openings"]:
            out["openings"].append(dict(o, id=f"{pre}{o['id']}", wall=wren[o["wall"]]))
        for o in sp["objects"]:
            out["objects"].append(dict(o, id=f"{pre}{o['id']}", room=ren.get(o["room"])))
    if any(p["scale"]["source"] == "guess" for p in parts):
        out["scale"] = {"source": "guess", "factor": parts[0]["scale"]["factor"]}
    return out


SCAN_EXT = {".roomplan", ".freescan"}   # the app's scans: already measured, no GPU needed


def has_scan(space_id: str) -> bool:
    return any(p.suffix in SCAN_EXT for p in (SPACES / space_id / "uploads").iterdir())


def free_space(meta: dict) -> dict:
    """space.json of a free scan: no rooms or walls, only the real scan. worker/fuse.py
    places it (lidar_frame) once the depth has been fused."""
    return {"version": 1, "id": meta["id"], "name": meta["name"], "kind": "free", "rooms": [], "walls": [],
            "openings": [], "objects": [], "scale": {"source": "lidar", "factor": 1.0}, "lidar_frame": {"auto": True}}


def process(space_id: str):
    d = SPACES / space_id
    meta = read_json(d / "meta.json")
    clips = sorted((read_json(p) for p in (d / "uploads").glob("*.json")), key=lambda c: c["uploaded"])
    clips = [c for c in clips if c]
    if not clips:
        raise RuntimeError("no uploaded clips")
    files = {c["id"]: next(p for p in (d / "uploads").iterdir() if p.stem == c["id"] and p.suffix != ".json")
             for c in clips}
    # A RoomPlan scan from the app is already measured: convert it, no GPU, and it wins
    # over any video in the same space (the newest scan if there are several).
    scans = [c for c in clips if files[c["id"]].suffix.lower() in SCAN_EXT]
    if scans:
        import roomplan
        set_status(d, "processing", "reading the LiDAR scan", 0.5)
        if files[scans[-1]["id"]].suffix.lower() == ".freescan":
            space = free_space(meta)
        else:
            space = roomplan.convert(read_json(files[scans[-1]["id"]]))
            space["id"] = meta["id"]
            space["name"] = meta["name"]
        write_json(d / "space.json", space)
        (d / "preview.ply").unlink(missing_ok=True)  # an older video's cloud would not line up
        drop_derived(d)                              # and so would a model of the scan before
        set_status(d, "done", "free scan" if space.get("kind") == "free" else f"{len(space['rooms'])} rooms", 1.0)
        return

    videos = [c for c in clips if files[c["id"]].suffix.lower() in VIDEO_EXT]
    if not videos:
        raise RuntimeError("LiDAR exports are not supported yet; please upload a video")

    work = d / "work"
    shutil.rmtree(work, ignore_errors=True)
    wall_len = (meta.get("scale") or {}).get("wall_length_m")
    walkthrough = meta.get("capture") != "per-room" or len(videos) == 1

    import torch
    import frames as fr
    import layout
    import recon
    import vision
    set_status(d, "processing", "loading model", 0.02)
    model = recon.load_model()
    try:
        # Walkthrough clips are one continuous sequence; per-room clips are separate scenes.
        groups = [videos] if walkthrough else [[v] for v in videos]
        parts, clouds, seen = [], [], []
        for gi, group in enumerate(groups):
            base, span = 0.05 + 0.9 * gi / len(groups), 0.9 / len(groups)
            frame_list = []
            for c in group:
                set_status(d, "processing", f"extracting frames ({c['filename']})", base)
                frame_list += fr.extract(files[c["id"]], work / c["id"])
            set_status(d, "processing", f"reconstructing 3D ({len(frame_list)} frames)", base + 0.1 * span)
            rec = recon.reconstruct(
                frame_list, model,
                progress=lambda p: set_status(d, "processing", "reconstructing 3D", base + span * (0.1 + 0.6 * p)))
            names = [c["room_name"]] if not walkthrough and group[0].get("room_name") else None
            sp, pts, cols, view = layout.build(
                rec, wall_length_m=wall_len if walkthrough else None, room_names=names,
                progress=lambda p, s: set_status(d, "processing", s, base + span * (0.7 + 0.3 * p)))
            parts.append(sp)
            clouds.append((pts, cols))
            seen.append((rec, frame_list, view))
    finally:
        del model
        gc.collect()
        torch.cuda.empty_cache()

    # The vision model runs only once VGGT is out of VRAM.
    if vision.available():
        try:
            for pi, (sp, (rec, frame_list, view)) in enumerate(zip(parts, seen)):
                found = vision.detect(sp, view, rec, frame_list, progress=lambda p, s: set_status(
                    d, "processing", s, 0.95 + 0.04 * (pi + p) / len(parts)))
                vision.apply(sp, found)
        finally:
            vision.unload()
    else:
        print(f"[{space_id}] vision model {vision.MODEL} not available; keeping the geometry guesses", flush=True)
    space = parts[0] if len(parts) == 1 else merge_spaces(parts)

    space["id"] = meta["id"]
    space["name"] = meta["name"]
    write_json(d / "space.json", space)
    if len(clouds) == 1:
        write_ply(d / "preview.ply", *clouds[0])
    shutil.rmtree(work, ignore_errors=True)
    set_status(d, "done", f"{len(space['rooms'])} rooms", 1.0)


def needs_mesh():
    """Spaces with a LiDAR depth file (.rgbd) newer than their fused model.

    The depth file is the biggest upload and lands after the scan was converted, so the
    model is its own step: it runs on the CPU and leaves the floor plan alone.
    """
    out = []
    for d in sorted(SPACES.glob("*")):
        rgbd = sorted((d / "uploads").glob("*.rgbd"), key=lambda p: p.stat().st_mtime)
        if not rgbd or uploading(d):   # a new scan's depth may still be on its way
            continue
        st = read_json(d / "status.json") or {}
        if st.get("state") != "done" or "lidar_frame" not in (read_json(d / "space.json") or {}):
            continue
        newest = rgbd[-1].stat().st_mtime
        done = [p for p in (d / "mesh.ply", d / "mesh.failed") if p.exists() and p.stat().st_mtime >= newest]
        if not done:
            out.append((d.name, rgbd[-1]))
    return out


DERIVED = ("mesh.ply", "mesh.failed", "textured.glb", "textured.failed", "splat.ply", "splat.splat", "splat.failed")


def drop_derived(d: Path):
    """Everything made from a scan's depth and photos; made again for the scan that replaces it."""
    for f in DERIVED:
        (d / f).unlink(missing_ok=True)
    shutil.rmtree(d / "exports", ignore_errors=True)


def side_job(space_id: str, what: str, out: str, fn):
    """A step after the floor plan is done (mesh, texture, splat). It reports progress in
    the space's status but leaves the floor plan's own result line alone; a failure is
    remembered in <out>.failed so it is not tried again until the inputs change."""
    d = SPACES / space_id
    st = read_json(d / "status.json") or {}
    if st.get("state") == "done":
        step = st.get("step", "")
    else:   # a job before this one was cut off (a restart): say what the space is instead
        space = read_json(d / "space.json") or {}
        step = "free scan" if space.get("kind") == "free" else f"{len(space.get('rooms', []))} rooms"
    failed = (d / out).with_suffix(".failed")
    try:
        set_status(d, "processing", what, 0.05)
        info = fn(d, lambda p, s=what: set_status(d, "processing", s, p))
        failed.unlink(missing_ok=True)
        shutil.rmtree(d / "exports", ignore_errors=True)   # they were made from the model before
        print(f"[{space_id}] {out}: {info}", flush=True)
    except Exception as e:
        traceback.print_exc()
        failed.write_text(str(e))
    set_status(d, "done", step, 1.0)  # the floor plan is unaffected either way


def build_mesh(space_id: str, rgbd: Path):
    def fn(d, progress):
        import fuse
        space = read_json(d / "space.json")
        tmp = d / "mesh.tmp.ply"   # Open3D picks the format from the extension
        try:
            info = fuse.fuse(rgbd, space["lidar_frame"], tmp, progress=progress)
        except Exception:
            tmp.unlink(missing_ok=True)
            raise
        if space["lidar_frame"].get("auto"):   # a free scan: fuse chose where the plan's origin is
            space["lidar_frame"] = info["frame"]
            space["bounds"] = info["bounds"]
            write_json(d / "space.json", space)
        tmp.replace(d / "mesh.ply")
        return info
    side_job(space_id, "building the 3D model from the depth", "mesh.ply", fn)


def uploading(d: Path) -> bool:
    """Files are still arriving (the video is the last and biggest). A stalled upload
    stops holding things up after an hour."""
    return any(time.time() - p.stat().st_mtime < 3600 for p in (d / "incoming").glob("*.part"))


def newer(target: Path, inputs: list[Path]) -> bool:
    """target (or its .failed note) exists and is not older than any input."""
    made = [p for p in (target, target.with_suffix(".failed")) if p.exists()]
    return bool(made) and max(p.stat().st_mtime for p in made) >= max(p.stat().st_mtime for p in inputs)


def photo_inputs(d: Path) -> list[Path]:
    import views
    (video, poses), rgbd = views.sources(d)
    return [p for p in (video, poses, rgbd) if p]


def needs_texture():
    """Spaces whose fused mesh has not been painted from the newest photos yet."""
    out = []
    for d in sorted(SPACES.glob("*")):
        if not (d / "mesh.ply").exists() or uploading(d):
            continue
        inputs = photo_inputs(d)
        if inputs and not newer(d / "textured.glb", inputs + [d / "mesh.ply"]):
            out.append(d.name)
    return out


def build_texture(space_id: str):
    def fn(d, progress):
        # Its own process: when it exits, every byte of VRAM it used is free again, which a
        # long-lived worker that once touched the GPU never quite manages.
        proc = subprocess.Popen([sys.executable, str(Path(__file__).with_name("texture.py")), str(d)],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        said = []
        for line in proc.stdout:
            pct, _, what = line.strip().partition("% ")
            if pct.isdigit():
                progress(int(pct) / 100, what)
            elif line.strip():
                said = (said + [line.strip()])[-5:]
        if proc.wait() != 0:
            raise RuntimeError(said[-1] if said else "the texture step failed")
        return said[-1] if said else ""
    side_job(space_id, "painting the 3D model from the photos", "textured.glb", fn)


def needs_splat():
    """Spaces someone asked a Gaussian splat for (splat.request, web/server.ts)."""
    out = []
    for d in sorted(SPACES.glob("*")):
        if (d / "splat.request").exists() and (d / "mesh.ply").exists() and not uploading(d):
            inputs = photo_inputs(d)
            if inputs and not newer(d / "splat.ply", inputs + [d / "splat.request"]):
                out.append(d.name)
    return out


def build_splat(space_id: str):
    def fn(d, progress):
        import splat
        return splat.build(d, progress=progress)
    side_job(space_id, "training the Gaussian splat", "splat.ply", fn)


def queued():
    """Spaces waiting for process(): the ones the server queued, and the ones whose newest
    scan arrived while a model was being built for the scan before (the server leaves a
    space alone while it is being processed)."""
    out = []
    for d in sorted(SPACES.glob("*")):
        st = read_json(d / "status.json")
        if not st:
            continue
        if st.get("state") == "queued":
            out.append((st.get("updated", ""), d.name))
        elif st.get("state") == "done" and (d / "space.json").exists():
            scans = [p.stat().st_mtime for p in (d / "uploads").iterdir() if p.suffix in SCAN_EXT]
            if scans and max(scans) > (d / "space.json").stat().st_mtime:
                out.append((st.get("updated", ""), d.name))
    return [sid for _, sid in sorted(out)]


def run_one(space_id: str):
    d = SPACES / space_id
    try:
        process(space_id)
    except Exception as e:
        traceback.print_exc()
        set_status(d, "failed", "error", 0, str(e))


def watch():
    print(f"watching {SPACES}, need {NEED_VRAM_MB} MB free VRAM", flush=True)
    waiting_note = None
    while True:
        q = queued()
        if q:
            free = free_vram_mb()
            if has_scan(q[0]) or free >= NEED_VRAM_MB:
                run_one(q[0])
                waiting_note = None
                continue
            if waiting_note != q[0]:
                set_status(SPACES / q[0], "queued", f"waiting for the GPU ({free} MB free)", 0)
                waiting_note = q[0]
        for space_id, rgbd in needs_mesh():
            build_mesh(space_id, rgbd)
        for space_id in needs_texture():
            build_texture(space_id)
        # A splat trains on the GPU for minutes: one per round, and only when it is free.
        want = needs_splat()
        if want and free_vram_mb() >= SPLAT_VRAM_MB:
            build_splat(want[0])
        time.sleep(10)


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).parent))
    if len(sys.argv) >= 2 and sys.argv[1] == "watch":
        watch()
    elif len(sys.argv) == 3 and sys.argv[1] == "process":
        run_one(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "mesh":
        rgbd = sorted((SPACES / sys.argv[2] / "uploads").glob("*.rgbd"), key=lambda p: p.stat().st_mtime)
        build_mesh(sys.argv[2], rgbd[-1]) if rgbd else print("no depth file")
    elif len(sys.argv) == 3 and sys.argv[1] == "texture":
        build_texture(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "splat":
        build_splat(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)
