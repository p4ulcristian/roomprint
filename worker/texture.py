"""Photo texture for the real-scan mesh: mesh.ply (vertex colours) -> textured.glb.

  python texture.py <space_dir>

The mesh is thinned and unwrapped into one texture atlas (xatlas). Every atlas texel knows
its place on the mesh; each posed photo of the walk (views.py) that sees that place
head-on, unoccluded and close paints it. A texel takes the views near its best one, so
the result stays sharp where one photo is clearly the best and has no hard seams where
two are equally good. What no photo saw keeps the fused vertex colour.

Everything is in the plan's coordinates (z up); the .glb is written y-up like glTF wants.
"""
import io
import json
import math
import sys
from pathlib import Path

import numpy as np

ATLAS = 4096
TRIANGLES = 250_000   # the textured mesh; detail comes from the photos now
MAX_VIEWS = 320
VIEW_WIDTH = 1920
DEPTH_DIV = 4         # occlusion depth is rendered at 1/4 of the photo's size
MAX_DIST = 6.0        # m; photos from further away are too coarse to help
MIN_COS = 0.2         # a photo must see the surface at less than ~78 degrees off head-on
NEAR_BEST = 0.75      # views this close to a texel's best weight share it
SHARPEN = 12.0        # ... with (weight / best) to this power
NEED_VRAM_MB = 3000   # below this the bake runs on the CPU (slower, same result)


def _device():
    import torch
    if torch.cuda.is_available():
        free, _ = torch.cuda.mem_get_info()
        if free / 1e6 >= NEED_VRAM_MB:
            return torch.device("cuda")
    return torch.device("cpu")


def _unwrap(V: np.ndarray, F: np.ndarray):
    import xatlas
    atlas = xatlas.Atlas()
    atlas.add_mesh(V, F)
    chart = xatlas.ChartOptions()
    chart.max_iterations = 1
    pack = xatlas.PackOptions()
    pack.resolution = ATLAS
    pack.padding = 4
    atlas.generate(chart_options=chart, pack_options=pack)
    vmap, faces, uv = atlas[0]
    return vmap, faces.astype(np.uint32), uv.astype(np.float32)


def _texels(uv, faces, W, H):
    """Which triangle each atlas texel lies in, and where: (texel index, face, b1, b2)."""
    import open3d as o3d
    import open3d.core as o3c
    flat = np.column_stack([uv * [W, H], np.zeros(len(uv))]).astype(np.float32)
    scene = o3d.t.geometry.RaycastingScene()
    scene.add_triangles(o3c.Tensor(flat), o3c.Tensor(faces))
    idx, face, b = [], [], []
    xs = np.arange(W, dtype=np.float32) + 0.5
    for y0 in range(0, H, 256):
        ys = np.arange(y0, min(H, y0 + 256), dtype=np.float32) + 0.5
        gx, gy = np.meshgrid(xs, ys)
        rays = np.zeros((gx.size, 6), np.float32)
        rays[:, 0], rays[:, 1], rays[:, 2], rays[:, 5] = gx.ravel(), gy.ravel(), 1.0, -1.0
        hit = scene.cast_rays(o3c.Tensor(rays))
        prim = hit["primitive_ids"].numpy()
        ok = np.flatnonzero(prim != scene.INVALID_ID)
        idx.append(ok + y0 * W)
        face.append(prim[ok])
        b.append(hit["primitive_uvs"].numpy()[ok])
    return np.concatenate(idx), np.concatenate(face), np.concatenate(b)


def _fill(img: np.ndarray, known: np.ndarray, rounds=12) -> np.ndarray:
    """Spread colours into the empty texels around each chart, so texture filtering never
    pulls in black at the chart edges."""
    import cv2
    img = img.astype(np.float32)
    known = known.astype(np.float32)
    for _ in range(rounds):
        num = cv2.blur(img * known[..., None], (3, 3))
        den = cv2.blur(known, (3, 3))
        grow = (known == 0) & (den > 0)
        img[grow] = num[grow] / den[grow][:, None]
        known[grow] = 1
    return np.clip(img, 0, 255).astype(np.uint8)


def bake(mesh_ply: Path, frame: dict, views: list, images, out: Path, progress=lambda p, s: None) -> dict:
    import open3d as o3d
    import open3d.core as o3c
    import torch
    import torch.nn.functional as tf
    import trimesh
    from PIL import Image
    from scipy.spatial import cKDTree

    import fuse

    progress(0.02, "thinning the mesh")
    full = o3d.io.read_triangle_mesh(str(mesh_ply))
    mesh = full.simplify_quadric_decimation(TRIANGLES) if len(full.triangles) > TRIANGLES else full
    mesh.remove_degenerate_triangles()
    mesh.remove_unreferenced_vertices()
    mesh.compute_vertex_normals()
    V = np.asarray(mesh.vertices, np.float32)
    F = np.asarray(mesh.triangles, np.uint32)
    base = np.asarray(full.vertex_colors, np.float32)[cKDTree(np.asarray(full.vertices)).query(V)[1]] \
        if full.has_vertex_colors() else np.full((len(V), 3), 0.7, np.float32)
    normals = np.asarray(mesh.vertex_normals, np.float32)

    progress(0.06, "unwrapping the mesh")
    vmap, faces, uv = _unwrap(V, F)
    W = H = ATLAS   # uv is 0..1, so the atlas can be any size; the packing leaves room for 4 px at about this
    V, normals, base = V[vmap], normals[vmap], base[vmap]
    progress(0.3, "laying out the texture")
    texel, face, b = _texels(uv, faces, W, H)
    wts = np.column_stack([1 - b[:, 0] - b[:, 1], b[:, 0], b[:, 1]]).astype(np.float32)
    corners = faces[face].astype(np.int64)
    at = lambda a: np.einsum("nk,nkc->nc", wts, a[corners])

    dev = _device()
    P = torch.from_numpy(at(V)).to(dev)
    N = tf.normalize(torch.from_numpy(at(normals)).to(dev), dim=1)
    colour = torch.from_numpy(at(base) * 255).to(dev)
    del wts, corners

    scene = o3d.t.geometry.RaycastingScene()
    scene.add_triangles(o3c.Tensor(V), o3c.Tensor(faces))
    M = fuse.to_plan(frame)

    def camera(v):
        """Centre and axes (right, down, forward) of a view in plan coordinates."""
        T = M @ v.T
        R = torch.tensor(T[:3, :3], dtype=torch.float32, device=dev)
        return torch.tensor(T[:3, 3], dtype=torch.float32, device=dev), R[:, 0], -R[:, 1], -R[:, 2]

    def depth_of(v):
        w, h = v.w // DEPTH_DIV, v.h // DEPTH_DIV
        K = v.K / DEPTH_DIV
        gx, gy = np.meshgrid(np.arange(w) + 0.5, np.arange(h) + 0.5)
        T = M @ v.T
        # ARKit's camera looks down -z with y up; the image has y down.
        d = np.stack([(gx - K[0, 2]) / K[0, 0], -(gy - K[1, 2]) / K[1, 1], -np.ones_like(gx)], -1) @ T[:3, :3].T
        rays = np.concatenate([np.broadcast_to(T[:3, 3], d.shape), d], -1).reshape(-1, 6).astype(np.float32)
        # the ray direction has forward length 1, so the hit distance is the depth itself
        return scene.cast_rays(o3c.Tensor(rays))["t_hit"].numpy().reshape(h, w)

    def weights(v, depth):
        C, right, down, fwd = camera(v)
        d = P - C
        z = d @ fwd
        zs = z.clamp(min=1e-3)
        px = v.K[0, 0] * (d @ right) / zs + v.K[0, 2]
        py = v.K[1, 1] * (d @ down) / zs + v.K[1, 2]
        dist = d.norm(dim=1).clamp(min=1e-3)
        cos = -(N * d).sum(1) / dist
        ok = (z > 0.15) & (dist < MAX_DIST) & (cos > MIN_COS) & (px > 2) & (px < v.w - 2) & (py > 2) & (py < v.h - 2)
        dm = torch.from_numpy(depth).to(dev)
        seen = dm[(py / DEPTH_DIV).long().clamp(0, dm.shape[0] - 1), (px / DEPTH_DIV).long().clamp(0, dm.shape[1] - 1)]
        ok &= (z - seen).abs() < 0.03 + 0.03 * z
        edge = (torch.minimum(torch.minimum(px, v.w - px), torch.minimum(py, v.h - py)) / (0.08 * v.w)).clamp(0, 1)
        w = cos * cos * edge / dist.clamp(min=0.5) ** 2
        return torch.where(ok, w, torch.zeros_like(w)), px, py

    # Pass 1: the best weight any view gives each texel.
    depths = []
    best = torch.zeros(len(P), device=dev)
    for i, v in enumerate(views):
        depths.append(depth_of(v))
        best = torch.maximum(best, weights(v, depths[-1])[0])
        if i % 20 == 0:
            progress(0.35 + 0.2 * i / len(views), "finding the best photo for every surface")

    # Pass 2: paint.
    acc = torch.zeros(len(P), 3, device=dev)
    accw = torch.zeros(len(P), device=dev)
    used = 0
    for i, (v, img) in enumerate(zip(views, images)):
        w, px, py = weights(v, depths[i])
        sel = torch.nonzero((w > 0) & (w >= NEAR_BEST * best)).squeeze(1)
        if len(sel):
            grid = torch.stack([(px[sel] + 0.5) / v.w * 2 - 1, (py[sel] + 0.5) / v.h * 2 - 1], 1).view(1, -1, 1, 2)
            pic = torch.tensor(img, device=dev).permute(2, 0, 1)[None].float()
            rgb = tf.grid_sample(pic, grid, mode="bilinear", align_corners=False)[0, :, :, 0].T
            ww = (w[sel] / best[sel]) ** SHARPEN
            acc.index_add_(0, sel, rgb * ww[:, None])
            accw.index_add_(0, sel, ww)
        used += 1
        if i % 10 == 0:
            progress(0.55 + 0.35 * i / len(views), "painting the mesh from the photos")
    if not used:
        raise ValueError("no photos to paint from")

    painted = accw > 0
    colour[painted] = acc[painted] / accw[painted][:, None]
    cover = float(painted.float().mean())
    img = np.zeros((H * W, 3), np.float32)
    known = np.zeros(H * W, bool)
    img[texel] = colour.cpu().numpy()
    known[texel] = True
    del P, N, colour, acc, accw, best
    progress(0.92, "writing the model")
    atlas = _fill(img.reshape(H, W, 3), known.reshape(H, W))

    buf = io.BytesIO()
    Image.fromarray(atlas).save(buf, "JPEG", quality=90)
    picture = Image.open(io.BytesIO(buf.getvalue()))   # reopened: trimesh then embeds it as JPEG
    material = trimesh.visual.material.PBRMaterial(baseColorTexture=picture, metallicFactor=0.0, roughnessFactor=1.0)
    # atlas rows run down from v = 0; trimesh keeps OBJ-style v (up) and flips it on export
    visual = trimesh.visual.TextureVisuals(uv=np.column_stack([uv[:, 0], 1 - uv[:, 1]]), material=material)
    yup = np.column_stack([V[:, 0], V[:, 2], -V[:, 1]])
    tm = trimesh.Trimesh(vertices=yup, faces=faces, visual=visual, process=False)
    tmp = out.with_suffix(".tmp.glb")
    tm.export(tmp)
    tmp.replace(out)
    return {"views": used, "triangles": len(faces), "atlas": [W, H], "covered": round(cover, 3), "device": dev.type}


def build(space_dir: Path, progress=lambda p, s: None) -> dict:
    """Texture a space's mesh from its best photos: the video with poses, else the depth file's."""
    import views as vw
    space = json.loads((space_dir / "space.json").read_text())
    (video, poses), rgbd = vw.sources(space_dir)
    if video:
        views, images = vw.from_video(video, poses, MAX_VIEWS, VIEW_WIDTH)
        source = "video"
    elif rgbd:
        views, images = vw.from_rgbd(rgbd, MAX_VIEWS)
        source = "depth photos"
    else:
        raise ValueError("no photos of this scan")
    info = bake(space_dir / "mesh.ply", space["lidar_frame"], views, images, space_dir / "textured.glb", progress)
    return dict(info, source=source)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.path.insert(0, str(Path(__file__).parent))
    print(build(Path(sys.argv[1]), progress=lambda p, s: print(f"{p:.0%} {s}", flush=True)))
