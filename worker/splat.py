"""Gaussian splat of a scan: its posed photos -> splat.ply (+ splat.splat for the viewer).

  python splat.py <space_dir>

Training is done by Brush (https://github.com/ArthurBrussee/brush), a prebuilt trainer
that runs on the GPU through Vulkan, so it needs no CUDA toolchain. BRUSH points at its
binary. It gets the photos and ARKit's poses in nerfstudio layout, in the plan's
coordinates, and starts from points on the fused mesh instead of from nothing, which
settles much sooner than a blind start.

splat.ply is the usual 3D Gaussian splatting file (colour only, no view-dependent terms,
to keep it small). splat.splat is the same in the compact 32-bytes-a-splat layout web
viewers load: position, scale, colour + opacity, rotation.
"""
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

import numpy as np

BRUSH = os.environ.get("BRUSH", "brush_app")
STEPS = int(os.environ.get("SPLAT_STEPS", "15000"))
MAX_SPLATS = 600_000
MAX_VIEWS = 300
WIDTH = 1280
START_POINTS = 200_000
SH_C0 = 0.28209479177387814


def dataset(space_dir: Path, work: Path) -> int:
    """Write the nerfstudio dataset Brush trains on; returns the number of photos."""
    from PIL import Image

    import export
    import fuse
    import views as vw
    space = json.loads((space_dir / "space.json").read_text())
    M = fuse.to_plan(space["lidar_frame"])
    (video, poses), rgbd = vw.sources(space_dir)
    if video:
        views, images = vw.from_video(video, poses, MAX_VIEWS, WIDTH)
    elif rgbd:
        views, images = vw.from_rgbd(rgbd, MAX_VIEWS)
    else:
        raise ValueError("no photos of this scan")
    (work / "images").mkdir(parents=True)
    frames = []
    for i, (v, img) in enumerate(zip(views, images)):
        name = f"images/frame_{i + 1:05d}.jpg"
        Image.fromarray(img).save(work / name, quality=92)
        frames.append({"file_path": name, "fl_x": v.K[0, 0], "fl_y": v.K[1, 1], "cx": v.K[0, 2], "cy": v.K[1, 2],
                       "w": v.w, "h": v.h, "transform_matrix": (M @ v.T).tolist()})
    if len(frames) < 10:
        raise ValueError("too few photos to train a splat from")
    pts, col = export.scan_points(space_dir, None)
    keep = np.random.default_rng(0).choice(len(pts), min(START_POINTS, len(pts)), replace=False)
    export.write_points(pts[keep], col[keep], "ply", work / "points.ply")
    (work / "transforms.json").write_text(json.dumps(
        {"camera_model": "OPENCV", "orientation_override": "none", "ply_file_path": "points.ply", "frames": frames}))
    return len(frames)


def read_ply(path: Path) -> np.ndarray:
    """The vertex table of a binary little-endian PLY as a structured array."""
    with open(path, "rb") as f:
        fields, count = [], 0
        while True:
            line = f.readline().decode().strip()
            if line.startswith("element vertex"):
                count = int(line.split()[-1])
            elif line.startswith("property"):
                _, typ, name = line.split()
                fields.append((name, {"float": "<f4", "double": "<f8", "uchar": "u1", "int": "<i4"}[typ]))
            elif line == "end_header":
                break
        return np.frombuffer(f.read(), np.dtype(fields), count=count)


def compact(ply: Path, out: Path) -> int:
    """splat.ply -> the 32-byte .splat layout, most visible splats first."""
    g = read_ply(ply)
    scale = np.exp(np.stack([g["scale_0"], g["scale_1"], g["scale_2"]], 1))
    opacity = 1 / (1 + np.exp(-g["opacity"]))
    order = np.argsort(-(scale.prod(1) * opacity))
    rec = np.empty(len(g), dtype=[("pos", "<f4", 3), ("scale", "<f4", 3), ("rgba", "u1", 4), ("rot", "u1", 4)])
    rec["pos"] = np.stack([g["x"], g["y"], g["z"]], 1)
    rec["scale"] = scale
    rgb = 0.5 + SH_C0 * np.stack([g["f_dc_0"], g["f_dc_1"], g["f_dc_2"]], 1)
    rec["rgba"] = np.clip(np.column_stack([rgb, opacity]) * 255, 0, 255)
    q = np.stack([g["rot_0"], g["rot_1"], g["rot_2"], g["rot_3"]], 1)
    q /= np.linalg.norm(q, axis=1, keepdims=True).clip(1e-9)
    rec["rot"] = np.clip(q * 128 + 128, 0, 255)
    tmp = out.with_name("tmp-" + out.name)
    tmp.write_bytes(rec[order].tobytes())
    tmp.replace(out)
    return len(g)


def build(space_dir: Path, progress=lambda p, s: None) -> dict:
    if not shutil.which(BRUSH):
        raise RuntimeError("the splat trainer is not installed on this machine (BRUSH)")
    work = space_dir / "work-splat"
    shutil.rmtree(work, ignore_errors=True)
    try:
        progress(0.03, "picking photos for the splat")
        n = dataset(space_dir, work / "data")
        t0 = time.time()
        # Brush keeps its GPU tuning notes in ./target; they live beside the spaces, not in the repo.
        cache = space_dir.parent.parent / "cache" / "brush"
        cache.mkdir(parents=True, exist_ok=True)
        proc = subprocess.Popen(
            [BRUSH, str(work / "data"), "--total-steps", str(STEPS), "--max-splats", str(MAX_SPLATS), "--sh-degree", "0",
             "--max-resolution", str(WIDTH), "--export-every", str(STEPS), "--export-path", str(work), "--export-name", "out.ply",
             "--eval-every", str(STEPS * 10)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=cache)
        tail = []

        def pump():   # Brush reports nothing we can count on, so its last lines are kept for an error
            for line in proc.stdout:
                tail.append(line.rstrip())
                del tail[:-20]
        threading.Thread(target=pump, daemon=True).start()
        guess = STEPS / 40   # seconds, roughly; only for the progress bar
        while proc.poll() is None:
            progress(min(0.95, 0.08 + 0.85 * (time.time() - t0) / guess), "training the Gaussian splat")
            time.sleep(5)
        if proc.returncode != 0 or not (work / "out.ply").exists():
            raise RuntimeError("the splat trainer failed: " + " | ".join(tail[-3:]))
        splats = compact(work / "out.ply", space_dir / "splat.splat")
        (work / "out.ply").replace(space_dir / "splat.ply")
        return {"photos": n, "splats": splats, "seconds": round(time.time() - t0)}
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.path.insert(0, str(Path(__file__).parent))
    print(build(Path(sys.argv[1]), progress=lambda p, s: print(f"{p:.0%} {s}", flush=True)))
