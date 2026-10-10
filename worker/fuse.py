"""Fuse the app's LiDAR depth frames (.rgbd, ios/Sources/Roomprint/DepthLog.swift) into
one coloured mesh of the real rooms, placed on the floor plan (space.json lidar_frame).

  python fuse.py <file.rgbd> <space.json> <out.ply>

Each frame's depth goes into a TSDF voxel grid (Open3D's tensor VoxelBlockGrid) from the pose ARKit tracked; only
depth the sensor is sure about is used. The camera JPEG of the same moment colours it.
"""
import io
import json
import math
import struct
import sys
import zlib
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

VOXEL = 0.02        # m; finer costs memory and shows the sensor's noise
TRUNC_VOXELS = 4.0  # TSDF truncation, in voxels
MIN_VIEWS = 2.0     # a surface must be seen in this many frames; drops one-off noise
BLOCKS = 200_000    # 16^3-voxel blocks reserved (grows if needed); enough for a flat
MAX_DEPTH = 4.0     # m; LiDAR gets noisy beyond this
MIN_CONF = 2        # ARKit confidence 0 low, 1 medium, 2 high
MAX_TRIANGLES = 600_000
MIN_PIECE = 200     # triangles; smaller floating bits are noise


def records(path: Path, jpeg=False):
    """Yield (header, JPEG bytes or None) per frame without unpacking the depth."""
    with open(path, "rb") as f:
        if f.read(4) != b"RPD1":
            raise ValueError("not a Roomprint depth file")
        while True:
            n = f.read(4)
            if len(n) < 4:
                return
            h = json.loads(f.read(struct.unpack("<I", n)[0]))
            f.seek(h["dz"] + h["cz"], 1)
            if not jpeg:
                f.seek(h["jz"], 1)
                yield h, None
                continue
            jz = f.read(h["jz"])
            if len(jz) < h["jz"]:
                return  # cut off mid-record
            yield h, jz


def frames(path: Path):
    """Yield (header, depth m (h, w) float32, confidence (h, w) uint8, rgb (jh, jw, 3))."""
    with open(path, "rb") as f:
        if f.read(4) != b"RPD1":
            raise ValueError("not a Roomprint depth file")
        while True:
            n = f.read(4)
            if len(n) < 4:
                return
            h = json.loads(f.read(struct.unpack("<I", n)[0]))
            dz, cz, jz = f.read(h["dz"]), f.read(h["cz"]), f.read(h["jz"])
            if len(jz) < h["jz"]:
                return  # cut off mid-record
            depth = np.frombuffer(zlib.decompress(dz, -15), np.float16).astype(np.float32).reshape(h["h"], h["w"])
            conf = np.frombuffer(zlib.decompress(cz, -15), np.uint8).reshape(h["h"], h["w"])
            rgb = np.asarray(Image.open(io.BytesIO(jz)).convert("RGB"))
            yield h, depth, conf, rgb


def fuse(path: Path, frame: dict, out: Path, progress=lambda p: None) -> dict:
    import open3d as o3d
    import open3d.core as o3c

    dev = o3c.Device("CPU:0")
    vbg = o3d.t.geometry.VoxelBlockGrid(
        attr_names=("tsdf", "weight", "color"), attr_dtypes=(o3c.float32, o3c.float32, o3c.float32),
        attr_channels=((1), (1), (3)), voxel_size=VOXEL, block_resolution=16, block_count=BLOCKS, device=dev)
    flip = np.diag([1.0, -1.0, -1.0, 1.0])  # ARKit camera looks down -z with y up; Open3D: +z, y down
    total = max(1, path.stat().st_size)
    used = 0
    for h, depth, conf, rgb in frames(path):
        jh, jw = rgb.shape[:2]
        depth = depth.copy()
        depth[(conf < MIN_CONF) | ~np.isfinite(depth) | (depth > MAX_DEPTH)] = 0
        depth = cv2.resize(depth, (jw, jh), interpolation=cv2.INTER_NEAREST)
        K = np.array(h["K"], float).reshape(3, 3) * (jw / h["iw"])
        K[2, 2] = 1.0
        K = o3c.Tensor(K, o3c.float64)
        world_to_cam = o3c.Tensor(np.linalg.inv(np.array(h["T"], float).reshape(4, 4).T @ flip), o3c.float64)
        d = o3d.t.geometry.Image(o3c.Tensor(np.ascontiguousarray(depth)))
        c = o3d.t.geometry.Image(o3c.Tensor(np.ascontiguousarray(rgb, dtype=np.float32) / 255.0))
        blocks = vbg.compute_unique_block_coordinates(d, K, world_to_cam, 1.0, MAX_DEPTH, TRUNC_VOXELS)
        vbg.integrate(blocks, d, c, K, K, world_to_cam, 1.0, MAX_DEPTH, TRUNC_VOXELS)
        used += 1
        if used % 20 == 0:
            progress(min(0.8, used * 200_000 / total))  # rough: ~200 kB a frame
    if not used:
        raise ValueError("the depth file has no frames")

    mesh = vbg.extract_triangle_mesh(weight_threshold=MIN_VIEWS).to_legacy()
    progress(0.85)
    if not len(mesh.triangles):
        raise ValueError("no surface came out of the depth")
    tri, counts, _ = mesh.cluster_connected_triangles()
    tri, counts = np.asarray(tri), np.asarray(counts)
    mesh.remove_triangles_by_mask(counts[tri] < MIN_PIECE)
    mesh.remove_unreferenced_vertices()
    if len(mesh.triangles) > MAX_TRIANGLES:
        mesh = mesh.simplify_quadric_decimation(MAX_TRIANGLES)
    progress(0.95)

    v = np.asarray(mesh.vertices)
    if frame.get("auto"):
        # A free scan has no floor plan to sit on: the plan's origin goes under the middle
        # of what was scanned, at its lowest surface.
        frame = {"theta": 0.0, "floor_y": round(float(np.percentile(v[:, 1], 0.5)), 4),
                 "origin": [round(float(v[:, 0].min() + v[:, 0].max()) / 2, 4),
                            round(float(-v[:, 2].min() - v[:, 2].max()) / 2, 4)]}
    # ARKit world -> floor plan: plan xy = rotate([x, -z], theta) - origin, height = y - floor_y
    th = frame["theta"]
    R = np.array([[math.cos(th), -math.sin(th)], [math.sin(th), math.cos(th)]])
    xy = np.stack([v[:, 0], -v[:, 2]], 1) @ R.T - np.array(frame["origin"])
    mesh.vertices = o3d.utility.Vector3dVector(np.column_stack([xy, v[:, 1] - frame["floor_y"]]))
    mesh.compute_vertex_normals()
    o3d.io.write_triangle_mesh(str(out), mesh, write_ascii=False, compressed=False, write_vertex_normals=False)
    lo, hi = np.asarray(mesh.vertices).min(0), np.asarray(mesh.vertices).max(0)
    return {"frames": used, "triangles": len(mesh.triangles), "frame": frame,
            "bounds": [[round(float(x), 3) for x in lo], [round(float(x), 3) for x in hi]]}


def to_plan(frame: dict) -> np.ndarray:
    """4x4 from ARKit world coordinates to the plan's (x, y on the floor, z up)."""
    c, s = math.cos(frame["theta"]), math.sin(frame["theta"])
    M = np.eye(4)
    M[:3, :3] = [[c, 0, s], [s, 0, -c], [0, 1, 0]]
    M[:3, 3] = [-frame["origin"][0], -frame["origin"][1], -frame["floor_y"]]
    return M


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(2)
    space = json.loads(Path(sys.argv[2]).read_text())
    print(fuse(Path(sys.argv[1]), space["lidar_frame"], Path(sys.argv[3]), progress=lambda p: print(f"{p:.0%}")))
