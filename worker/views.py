"""Posed photos of a scan: the camera images with where each was taken from.

Two sources, best first:
  video + pose track  the walk video (.mov, full camera resolution) and the app's .poses
                      file (ios/Sources/Roomprint/PoseLog.swift): one pose per video frame
  depth file          the small JPEGs kept in the .rgbd file, five a second

Poses are ARKit's: camera to world, the camera looking down -z with y up. Intrinsics are
for the image as the sensor gives it (landscape), origin top left.

.poses format, little-endian: magic "RPP1", u32 header length, header JSON {iw, ih}, then
one 88-byte record per video frame: f64 t (the frame's time in the video, s), f32 fx, fy,
cx, cy, f32[16] camera to world (column-major).
"""
import json
import struct
import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np

RECORD = np.dtype([("t", "<f8"), ("k", "<f4", 4), ("T", "<f4", 16)])


@dataclass
class View:
    K: np.ndarray       # 3x3, at (w, h)
    T: np.ndarray       # 4x4 camera to world, ARKit axes
    w: int
    h: int
    index: int = 0      # video frame number or depth record number


def read_poses(path: Path) -> dict:
    with open(path, "rb") as f:
        if f.read(4) != b"RPP1":
            raise ValueError("not a Roomprint pose file")
        head = json.loads(f.read(struct.unpack("<I", f.read(4))[0]))
        raw = f.read()
    rec = np.frombuffer(raw[: len(raw) // RECORD.itemsize * RECORD.itemsize], RECORD)
    return {"iw": head["iw"], "ih": head["ih"], "t": rec["t"].copy(), "k": rec["k"].astype(float),
            "T": rec["T"].astype(float).reshape(-1, 4, 4).transpose(0, 2, 1)}


def _motion(T: np.ndarray, t: np.ndarray):
    """Per-frame step (m) and turn (rad) since the frame before, and a blur score."""
    step = np.zeros(len(T))
    turn = np.zeros(len(T))
    if len(T) > 1:
        step[1:] = np.linalg.norm(T[1:, :3, 3] - T[:-1, :3, 3], axis=1)
        rel = np.einsum("nij,nkj->nik", T[1:, :3, :3], T[:-1, :3, :3])
        turn[1:] = np.arccos(np.clip((np.trace(rel, axis1=1, axis2=2) - 1) / 2, -1, 1))
    dt = np.maximum(np.diff(t, prepend=t[0] - 1 / 30), 1e-3)
    return step, turn, (turn + 0.5 * step) / dt   # turning blurs more than walking


def pick(T: np.ndarray, t: np.ndarray, max_views: int, step_m=0.2, turn_rad=0.17, ahead=6) -> list[int]:
    """Frames spread over the walk: a new one after every bit of movement, and of the next
    few candidates the steadiest (least motion blur). Thinned evenly to max_views."""
    step, turn, blur = _motion(T, t)
    scale = 1.0
    while True:
        out, moved, turned, i = [], 1e9, 1e9, 0
        while i < len(T):
            moved += step[i]
            turned += turn[i]
            if moved >= step_m * scale or turned >= turn_rad * scale:
                j = i + int(np.argmin(blur[i:i + ahead]))
                out.append(j)
                moved = turned = 0.0
                i = j
            i += 1
        if len(out) <= max_views:
            return out
        scale *= max(1.1, len(out) / max_views)


def video_times(video: Path) -> np.ndarray:
    """Presentation time of every frame, in display order."""
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time",
                          "-of", "csv=p=0", str(video)], capture_output=True, text=True, check=True).stdout
    return np.sort(np.array([float(x.strip(",")) for x in out.split() if x.strip(",") not in ("", "N/A")]))


def video_frames(video: Path, numbers: list[int], w: int, h: int):
    """Yield the given frames (display order numbers, ascending) as (h, w, 3) RGB arrays,
    unrotated: the way the sensor saw them, which is what the intrinsics describe."""
    if not numbers:
        return
    # ffmpeg's expression parser gives up on a long flat sum; a balanced one stays shallow
    def any_of(ns):
        if len(ns) == 1:
            return f"eq(n\\,{ns[0]})"
        return f"({any_of(ns[:len(ns) // 2])}+{any_of(ns[len(ns) // 2:])})"
    sel = any_of(numbers)
    cmd = ["ffmpeg", "-v", "error", "-noautorotate", "-i", str(video), "-an",
           "-vf", f"select='{sel}',scale={w}:{h}", "-fps_mode", "passthrough",
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    try:
        size = w * h * 3
        for _ in numbers:
            buf = p.stdout.read(size)
            if len(buf) < size:
                return
            yield np.frombuffer(buf, np.uint8).reshape(h, w, 3)
    finally:
        p.stdout.close()
        p.terminate()
        p.wait()


def from_video(video: Path, poses: Path, max_views: int, width: int):
    """(views, images): the picked video frames with their poses; images is a generator
    in the same order."""
    tr = read_poses(poses)
    times = video_times(video)
    if not len(times) or not len(tr["t"]):
        raise ValueError("the video or its pose track is empty")
    # Each pose belongs to the video frame with the same timestamp.
    n = np.clip(np.searchsorted(times, tr["t"]), 1, len(times) - 1)
    n = np.where(np.abs(times[n - 1] - tr["t"]) <= np.abs(times[n] - tr["t"]), n - 1, n)
    ok = np.abs(times[n] - tr["t"]) < 0.02
    keep = [i for i in pick(tr["T"], tr["t"], max_views) if ok[i]]
    keep = sorted({int(n[i]): i for i in keep}.items())   # one pose per video frame, in video order
    w = min(width, tr["iw"])
    h = round(tr["ih"] * w / tr["iw"] / 2) * 2
    views = []
    for num, i in keep:
        fx, fy, cx, cy = tr["k"][i] * (w / tr["iw"])
        views.append(View(np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1.0]]), tr["T"][i], w, h, num))
    return views, video_frames(video, [v.index for v in views], w, h)


def from_rgbd(rgbd: Path, max_views: int):
    """(views, images) from the depth file's own small photos."""
    import io

    from PIL import Image

    import fuse

    heads = [h for h, _ in fuse.records(rgbd)]
    if not heads:
        raise ValueError("the depth file has no frames")
    T = np.array([np.array(h["T"], float).reshape(4, 4).T for h in heads])
    keep = set(pick(T, np.array([h["t"] for h in heads]), max_views, ahead=2))
    views = []
    for i, h in enumerate(heads):
        if i in keep:
            K = np.array(h["K"], float).reshape(3, 3) * (h["jw"] / h["iw"])
            K[2, 2] = 1.0
            views.append(View(K, T[i], h["jw"], h["jh"], i))

    def images():
        for i, (h, jpeg) in enumerate(fuse.records(rgbd, jpeg=True)):
            if i in keep:
                yield np.asarray(Image.open(io.BytesIO(jpeg)).convert("RGB"))
    return views, images()


def sources(space_dir: Path):
    """The newest video with a pose track, and the newest depth file, of a space's uploads."""
    up = space_dir / "uploads"
    newest = lambda pat: max(up.glob(pat), key=lambda p: p.stat().st_mtime, default=None)
    poses = newest("*.poses")
    video = None
    if poses:
        # The app names both walk-<stamp>.*; the clip records keep those names.
        want = _filename(poses).rsplit(".", 1)[0]
        for p in list(up.glob("*.mov")) + list(up.glob("*.mp4")):
            if _filename(p).rsplit(".", 1)[0] == want:
                video = p
    return (video, poses) if video else (None, None), newest("*.rgbd")


def _filename(p: Path) -> str:
    try:
        return json.loads(p.with_suffix(".json").read_text())["filename"]
    except Exception:
        return p.name
