"""Video -> sharp, evenly spaced frames sized for VGGT (long side 518, dims multiple of 14)."""
import subprocess
from pathlib import Path

import cv2
import numpy as np

LONG_SIDE = 518
PATCH = 14


def _target_size(w: int, h: int) -> tuple[int, int]:
    s = LONG_SIDE / max(w, h)
    return (max(PATCH, round(w * s / PATCH) * PATCH), max(PATCH, round(h * s / PATCH) * PATCH))


def extract(video: Path, out_dir: Path, fps: float = 2.0, oversample: int = 3, max_frames: int = 400) -> list[Path]:
    """Decode at fps*oversample (ffmpeg applies the phone's rotation), keep the sharpest
    frame of every `oversample` consecutive ones, then thin evenly to max_frames."""
    raw = out_dir / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-i", str(video),
         "-vf", f"fps={fps * oversample},scale='if(gt(iw,ih),960,-2)':'if(gt(iw,ih),-2,960)'",
         "-q:v", "2", str(raw / "%05d.jpg")],
        check=True,
    )
    files = sorted(raw.glob("*.jpg"))
    if not files:
        raise RuntimeError(f"no frames decoded from {video.name}")

    def sharpness(p: Path) -> float:
        g = cv2.imread(str(p), cv2.IMREAD_GRAYSCALE)
        return cv2.Laplacian(g, cv2.CV_64F).var()

    picked = [max(files[i:i + oversample], key=sharpness) for i in range(0, len(files), oversample)]
    if len(picked) > max_frames:
        idx = np.linspace(0, len(picked) - 1, max_frames).round().astype(int)
        picked = [picked[i] for i in idx]

    frames = out_dir / "frames"
    frames.mkdir(exist_ok=True)
    out = []
    for i, p in enumerate(picked):
        img = cv2.imread(str(p))
        h, w = img.shape[:2]
        img = cv2.resize(img, _target_size(w, h), interpolation=cv2.INTER_AREA)
        dst = frames / f"{i:05d}.jpg"
        cv2.imwrite(str(dst), img, [cv2.IMWRITE_JPEG_QUALITY, 95])
        out.append(dst)
    for p in files:
        p.unlink()
    raw.rmdir()
    return out
