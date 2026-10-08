"""Frames -> one coloured point cloud + camera poses, using VGGT on overlapping chunks.

VGGT only fits ~40 frames at a time in 16 GB, so a long walkthrough runs in chunks
that share `overlap` frames. Each chunk comes out in its own coordinate frame and
scale; the shared frames give pixel-exact correspondences (same image, same pixel),
so we fit a similarity transform per chunk onto the ones before it.
"""
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import cv2
import numpy as np
import torch

MODEL_ID = "facebook/VGGT-1B"


@dataclass
class Recon:
    points: np.ndarray    # (N, 3) float32, world = first camera of the first chunk
    colors: np.ndarray    # (N, 3) uint8
    conf: np.ndarray      # (N,) float32
    cam_centers: np.ndarray  # (F, 3)
    cam_rots: np.ndarray     # (F, 3, 3) camera-to-world rotation (OpenCV: x right, y down, z forward)
    intr: np.ndarray         # (F, 3, 3) pinhole intrinsics in frame pixels


def umeyama(src: np.ndarray, dst: np.ndarray, w: np.ndarray | None = None):
    """Weighted similarity transform with dst ~ s * R @ src + t."""
    w = np.ones(len(src)) if w is None else w
    w = w / w.sum()
    mu_s, mu_d = w @ src, w @ dst
    xs, xd = src - mu_s, dst - mu_d
    cov = (xd * w[:, None]).T @ xs
    U, D, Vt = np.linalg.svd(cov)
    S = np.eye(3)
    if np.linalg.det(U) * np.linalg.det(Vt) < 0:
        S[2, 2] = -1
    R = U @ S @ Vt
    var_s = (w * (xs ** 2).sum(1)).sum()
    s = np.trace(np.diag(D) @ S) / var_s
    t = mu_d - s * R @ mu_s
    return s, R, t


def robust_sim3(src, dst, w, iters=5, keep=0.8):
    """Umeyama, then refit on the best `keep` fraction a few times (drops moving/bad pixels)."""
    idx = np.arange(len(src))
    for _ in range(iters):
        s, R, t = umeyama(src[idx], dst[idx], w[idx])
        err = np.linalg.norm((s * (R @ src.T)).T + t - dst, axis=1)
        idx = np.argsort(err)[: int(len(src) * keep)]
    return s, R, t


def load_model(device="cuda"):
    from vggt.models.vggt import VGGT
    model = VGGT.from_pretrained(MODEL_ID).to(device).eval()
    # Only cameras + depth are used; dropping the other heads saves VRAM.
    model.point_head = None
    model.track_head = None
    return model


def _run_chunk(model, imgs: torch.Tensor, device="cuda"):
    from vggt.utils.pose_enc import pose_encoding_to_extri_intri
    from vggt.utils.geometry import unproject_depth_map_to_point_map
    x = imgs.to(device)[None]
    with torch.no_grad(), torch.autocast("cuda", dtype=torch.bfloat16):
        tokens, ps_idx = model.aggregator(x)
        pose_enc = model.camera_head(tokens)[-1]
        depth, depth_conf = model.depth_head(tokens, x, ps_idx)
    extr, intr = pose_encoding_to_extri_intri(pose_enc, x.shape[-2:])
    extr = extr[0].float().cpu().numpy()
    intr = intr[0].float().cpu().numpy()
    depth = depth[0].float().cpu().numpy()
    conf = depth_conf[0].float().cpu().numpy()
    pts = unproject_depth_map_to_point_map(depth, extr, intr)  # (S, H, W, 3)
    del tokens
    torch.cuda.empty_cache()
    return pts.astype(np.float32), conf.astype(np.float32), extr, intr


def reconstruct(frames: list[Path], model, chunk=32, overlap=8, stride_px=2,
                progress: Callable[[float], None] = lambda p: None) -> Recon:
    rgb = [cv2.cvtColor(cv2.imread(str(f)), cv2.COLOR_BGR2RGB) for f in frames]
    imgs = torch.from_numpy(np.stack(rgb)).permute(0, 3, 1, 2).float() / 255.0
    n = len(frames)
    starts = [0] if n <= chunk else list(range(0, n - overlap, chunk - overlap))

    world_pts: list[np.ndarray | None] = [None] * n  # full-res points per frame, global coords
    world_conf: list[np.ndarray | None] = [None] * n
    centers = np.zeros((n, 3))
    rots = np.zeros((n, 3, 3))
    intrs = np.zeros((n, 3, 3))

    for ci, s0 in enumerate(starts):
        s1 = min(s0 + chunk, n)
        pts, conf, extr, intr = _run_chunk(model, imgs[s0:s1])
        R_c = extr[:, :, :3]
        t_c = extr[:, :, 3]
        C = -np.einsum("sji,sj->si", R_c, t_c)  # camera centres in chunk coords
        Rcw = R_c.transpose(0, 2, 1)

        if ci == 0:
            s, R, t = 1.0, np.eye(3), np.zeros(3)
        else:
            shared = [i for i in range(s0, s1) if world_pts[i] is not None]
            src, dst, w = [], [], []
            for i in shared:
                a, ca = pts[i - s0], conf[i - s0]
                b, cb = world_pts[i], world_conf[i]
                m = (ca > np.median(ca)) & (cb > np.median(cb))
                src.append(a[m]); dst.append(b[m]); w.append(np.minimum(ca[m], cb[m]))
            src, dst, w = np.concatenate(src), np.concatenate(dst), np.concatenate(w)
            if len(src) > 60000:
                sel = np.random.default_rng(0).choice(len(src), 60000, replace=False)
                src, dst, w = src[sel], dst[sel], w[sel]
            s, R, t = robust_sim3(src.astype(np.float64), dst.astype(np.float64), w.astype(np.float64))

        for j, i in enumerate(range(s0, s1)):
            if world_pts[i] is not None:
                continue  # keep the earlier chunk's version of shared frames
            world_pts[i] = (s * (pts[j].reshape(-1, 3) @ R.T) + t).reshape(pts[j].shape).astype(np.float32)
            world_conf[i] = conf[j]
            centers[i] = s * R @ C[j] + t
            rots[i] = R @ Rcw[j]
            intrs[i] = intr[j]
        progress((ci + 1) / len(starts))

    P, Cl, Cf = [], [], []
    for i in range(n):
        p = world_pts[i][::stride_px, ::stride_px].reshape(-1, 3)
        c = rgb[i][::stride_px, ::stride_px].reshape(-1, 3)
        f = world_conf[i][::stride_px, ::stride_px].reshape(-1)
        P.append(p); Cl.append(c); Cf.append(f)
    return Recon(np.concatenate(P), np.concatenate(Cl), np.concatenate(Cf), centers, rots, intrs)
