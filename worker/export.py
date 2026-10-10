"""Exports of a space, made on demand by the web server (web/server.ts), which caches them.

  python export.py <space_dir> <kind> <format> <out_file> [x0,y0,z0,x1,y1,z1]

  kind    formats
  mesh    glb obj usdz stl ply   the real scan (photo-textured when textured.glb exists)
  points  ply las xyz            points sampled from the real scan (or the video's cloud)
  model   glb obj usdz stl       the drawn model: walls with openings, floors, furniture
  plan    dxf                    the floor plan for CAD (svg, pdf, png come from the web server)
  raw     zip                    the scan's photos, depth and camera poses, nerfstudio layout

The optional box crops mesh and points (plan coordinates, metres). Files that have an up
axis by habit follow it: glb, obj and usdz are y-up; stl, ply, las, xyz and dxf keep the
plan's z-up. obj comes zipped with its material and texture.
"""
import io
import json
import math
import sys
import tempfile
import zipfile
from pathlib import Path

import numpy as np

POINTS_PER_M2 = 40_000
MAX_POINTS = 3_000_000
FORMATS = {"mesh": {"glb", "obj", "usdz", "stl", "ply"}, "points": {"ply", "las", "xyz"},
           "model": {"glb", "obj", "usdz", "stl"}, "plan": {"dxf"}, "raw": {"zip"}}
ROOM_COLORS = ["#dcebf7", "#f7e7d4", "#e0f0dc", "#efe0f3", "#f7f0c8", "#d9efee", "#f6dcdc"]
FURN_COLORS = ["#c9b79c", "#a9c1d9", "#b7cfa8", "#d6b3b3", "#c7bddf", "#e2cf9a", "#a8cfc8"]


# ---------- the real scan ----------

def load_scan(d: Path):
    """The real scan in plan coordinates (z up): textured if it has been, else vertex colours."""
    import trimesh
    if (d / "textured.glb").exists():
        m = trimesh.load(d / "textured.glb", force="mesh", process=False)
        m.vertices = np.column_stack([m.vertices[:, 0], -m.vertices[:, 2], m.vertices[:, 1]])
        # reopened as a JPEG, so writers keep it one instead of a PNG several times the size
        from PIL import Image
        buf = io.BytesIO()
        m.visual.material.baseColorTexture.convert("RGB").save(buf, "JPEG", quality=90)
        m.visual.material.baseColorTexture = Image.open(io.BytesIO(buf.getvalue()))
        return m
    if (d / "mesh.ply").exists():
        return trimesh.load(d / "mesh.ply", process=False)
    raise FileNotFoundError("this space has no real scan")


def crop(m, box):
    """Drop every triangle that reaches outside the box."""
    if box is None:
        return m
    lo, hi = np.array(box[:3]), np.array(box[3:])
    inside = np.all((m.vertices >= lo) & (m.vertices <= hi), axis=1)
    m.update_faces(inside[m.faces].all(axis=1))
    m.remove_unreferenced_vertices()
    if not len(m.faces):
        raise ValueError("nothing is left inside the crop box")
    return m


def y_up(m):
    """In place: a copy would turn the JPEG texture into a PNG several times the size."""
    m.vertices = np.column_stack([m.vertices[:, 0], m.vertices[:, 2], -m.vertices[:, 1]])
    return m


def textured(m) -> bool:
    return getattr(m.visual, "kind", None) == "texture" and getattr(m.visual.material, "baseColorTexture", None) is not None


def vertex_colours(m):
    """(n, 3) floats 0..1, whatever the mesh carries."""
    vis = m.visual.to_color() if textured(m) else m.visual
    try:
        return np.asarray(vis.vertex_colors, float)[:, :3] / 255
    except Exception:
        return np.full((len(m.vertices), 3), 0.75)


def write_obj_zip(m, out: Path, name: str):
    from trimesh.exchange.obj import export_obj
    text, files = export_obj(y_up(m), include_color=True, include_texture=True, return_texture=True, mtl_name=f"{name}.mtl")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(f"{name}.obj", text)
        for fname, data in files.items():
            z.writestr(fname, data)


def write_usdz(m, out: Path):
    """USDZ that opens in AR Quick Look: one mesh, a preview surface, the texture beside it."""
    from pxr import Sdf, Usd, UsdGeom, UsdShade, UsdUtils, Vt
    m = y_up(m)
    with tempfile.TemporaryDirectory() as td:
        usd = Path(td) / "model.usdc"
        stage = Usd.Stage.CreateNew(str(usd))
        UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
        UsdGeom.SetStageMetersPerUnit(stage, 1.0)
        root = UsdGeom.Xform.Define(stage, "/Model")
        stage.SetDefaultPrim(root.GetPrim())
        mesh = UsdGeom.Mesh.Define(stage, "/Model/Scan")
        V = np.asarray(m.vertices, np.float32)
        mesh.CreatePointsAttr(Vt.Vec3fArray.FromNumpy(V))
        mesh.CreateFaceVertexCountsAttr(Vt.IntArray.FromNumpy(np.full(len(m.faces), 3, np.int32)))
        mesh.CreateFaceVertexIndicesAttr(Vt.IntArray.FromNumpy(np.asarray(m.faces, np.int32).ravel()))
        mesh.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
        mesh.CreateExtentAttr(Vt.Vec3fArray.FromNumpy(np.stack([V.min(0), V.max(0)])))
        mesh.CreateDoubleSidedAttr(True)

        material = UsdShade.Material.Define(stage, "/Model/Material")
        surface = UsdShade.Shader.Define(stage, "/Model/Material/Surface")
        surface.CreateIdAttr("UsdPreviewSurface")
        surface.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(1.0)
        surface.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(0.0)
        diffuse = surface.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f)
        prims = UsdGeom.PrimvarsAPI(mesh)
        if textured(m):
            m.visual.material.baseColorTexture.convert("RGB").save(Path(td) / "texture.jpg", quality=90)
            prims.CreatePrimvar("st", Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.vertex) \
                .Set(Vt.Vec2fArray.FromNumpy(np.asarray(m.visual.uv, np.float32)))
            reader = UsdShade.Shader.Define(stage, "/Model/Material/St")
            reader.CreateIdAttr("UsdPrimvarReader_float2")
            reader.CreateInput("varname", Sdf.ValueTypeNames.Token).Set("st")
            tex = UsdShade.Shader.Define(stage, "/Model/Material/Texture")
            tex.CreateIdAttr("UsdUVTexture")
            tex.CreateInput("file", Sdf.ValueTypeNames.Asset).Set("texture.jpg")
            tex.CreateInput("st", Sdf.ValueTypeNames.Float2).ConnectToSource(
                reader.CreateOutput("result", Sdf.ValueTypeNames.Float2))
            diffuse.ConnectToSource(tex.CreateOutput("rgb", Sdf.ValueTypeNames.Float3))
        else:
            prims.CreatePrimvar("displayColor", Sdf.ValueTypeNames.Color3fArray, UsdGeom.Tokens.vertex) \
                .Set(Vt.Vec3fArray.FromNumpy(vertex_colours(m).astype(np.float32)))
            reader = UsdShade.Shader.Define(stage, "/Model/Material/Colour")
            reader.CreateIdAttr("UsdPrimvarReader_float3")
            reader.CreateInput("varname", Sdf.ValueTypeNames.Token).Set("displayColor")
            diffuse.ConnectToSource(reader.CreateOutput("result", Sdf.ValueTypeNames.Float3))
        material.CreateSurfaceOutput().ConnectToSource(surface.ConnectableAPI(), "surface")
        UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(material)
        stage.Save()
        if not UsdUtils.CreateNewARKitUsdzPackage(Sdf.AssetPath(str(usd)), str(out)):
            raise RuntimeError("could not package the USDZ")


def write_mesh(m, fmt: str, out: Path, name: str):
    if fmt == "glb":
        y_up(m).export(out, file_type="glb")
    elif fmt == "obj":
        write_obj_zip(m, out, name)
    elif fmt == "usdz":
        write_usdz(m, out)
    elif fmt == "stl":
        m.export(out, file_type="stl")
    elif fmt == "ply":
        import trimesh
        col = (vertex_colours(m) * 255).astype(np.uint8)
        trimesh.Trimesh(m.vertices, m.faces, vertex_colors=col, process=False).export(out, file_type="ply")


# ---------- points ----------

def scan_points(d: Path, box):
    """(points (n, 3), colours (n, 3) uint8) in plan coordinates."""
    import trimesh
    try:
        m = crop(load_scan(d), box)
    except FileNotFoundError:
        if not (d / "preview.ply").exists():
            raise
        pc = trimesh.load(d / "preview.ply", process=False)
        pts = np.asarray(pc.vertices)
        col = np.asarray(pc.colors)[:, :3] if len(getattr(pc, "colors", [])) else np.full((len(pts), 3), 160, np.uint8)
        if box is not None:
            keep = np.all((pts >= box[:3]) & (pts <= box[3:]), axis=1)
            pts, col = pts[keep], col[keep]
        return pts, col.astype(np.uint8)
    n = int(np.clip(m.area * POINTS_PER_M2, 200_000, MAX_POINTS))
    rng = np.random.default_rng(0)
    areas = m.area_faces
    face = rng.choice(len(m.faces), n, p=areas / areas.sum())
    r1, r2 = np.sqrt(rng.random(n)), rng.random(n)
    w = np.column_stack([1 - r1, r1 * (1 - r2), r1 * r2])   # uniform over each triangle
    tri = m.faces[face]
    pts = np.einsum("nk,nkc->nc", w, m.vertices[tri])
    if textured(m):
        tex = np.asarray(m.visual.material.baseColorTexture.convert("RGB"))
        uv = np.einsum("nk,nkc->nc", w, np.asarray(m.visual.uv)[tri])
        col = tex[np.clip(((1 - uv[:, 1]) * tex.shape[0]).astype(int), 0, tex.shape[0] - 1),
                  np.clip((uv[:, 0] * tex.shape[1]).astype(int), 0, tex.shape[1] - 1)]
    else:
        col = np.einsum("nk,nkc->nc", w, vertex_colours(m)[tri]) * 255
    return pts, col.astype(np.uint8)


def write_points(pts, col, fmt: str, out: Path):
    if fmt == "ply":
        rec = np.empty(len(pts), dtype=[("x", "<f4"), ("y", "<f4"), ("z", "<f4"), ("red", "u1"), ("green", "u1"), ("blue", "u1")])
        rec["x"], rec["y"], rec["z"] = pts.T
        rec["red"], rec["green"], rec["blue"] = col.T
        head = ("ply\nformat binary_little_endian 1.0\n" f"element vertex {len(rec)}\n"
                "property float x\nproperty float y\nproperty float z\n"
                "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n")
        out.write_bytes(head.encode() + rec.tobytes())
    elif fmt == "las":
        import laspy
        header = laspy.LasHeader(point_format=2, version="1.2")
        header.scales = [0.001] * 3
        header.offsets = np.floor(pts.min(0))
        las = laspy.LasData(header)
        las.x, las.y, las.z = pts.T
        las.red, las.green, las.blue = (col.astype(np.uint16) * 257).T   # LAS colours are 16 bit
        las.write(str(out))
    elif fmt == "xyz":
        np.savetxt(out, np.column_stack([pts, col]), fmt="%.4f %.4f %.4f %d %d %d")


# ---------- plan geometry (the same rules as web/public/geom.js) ----------

def wall_frame(w):
    a, b = np.array(w["a"], float), np.array(w["b"], float)
    L = float(np.linalg.norm(b - a))
    dv = (b - a) / (L or 1)
    return {"L": L, "d": dv, "n": np.array([-dv[1], dv[0]]), "angle": math.atan2(dv[1], dv[0])}


def along(w, f, u, v=0.0):
    return np.array(w["a"], float) + f["d"] * u + f["n"] * v


def wall_openings(space, w):
    L = wall_frame(w)["L"]
    out = []
    for o in space["openings"]:
        if o["wall"] == w["id"]:
            u0, u1 = max(0.0, o["offset"]), min(L, o["offset"] + o["width"])
            if u1 > u0:
                out.append(dict(o, u0=u0, u1=u1))
    return sorted(out, key=lambda o: o["u0"])


def area(poly):
    p = np.array(poly, float)
    return 0.5 * float(p[:, 0] @ np.roll(p[:, 1], -1) - p[:, 1] @ np.roll(p[:, 0], -1))


def centroid(poly):
    p = np.array(poly, float)
    a = area(poly)
    if abs(a) < 1e-9:
        return p.mean(0)
    q = np.roll(p, -1, 0)
    f = p[:, 0] * q[:, 1] - q[:, 0] * p[:, 1]
    return ((p + q) * f[:, None]).sum(0) / (6 * a)


def room_side(space, w, room_id):
    room = next((r for r in space["rooms"] if r["id"] == room_id), None)
    if not room:
        return 1
    f = wall_frame(w)
    return 1 if (centroid(room["polygon"]) - along(w, f, f["L"] / 2)) @ f["n"] >= 0 else -1


def outward_side(space, w):
    return -room_side(space, w, w["rooms"][0]) if len(w["rooms"]) == 1 else None


def normalize(space):
    for k in ("rooms", "walls", "openings", "objects"):
        space.setdefault(k, [])
    h = space["rooms"][0].get("height", 2.5) if space["rooms"] else 2.5
    for w in space["walls"]:
        w.setdefault("thickness", 0.12)
        w.setdefault("height", h)
        w.setdefault("rooms", [])
    for o in space["openings"]:
        o.setdefault("sill", 0.9 if o["type"] == "window" else 0)
        o.setdefault("height", 1.2 if o["type"] == "window" else 2.05)
    for f in space["objects"]:
        f.setdefault("yaw", 0)
        f.setdefault("label", "object")
    return space


# ---------- the drawn model ----------

def _rgb(hex_):
    return [int(hex_[i:i + 2], 16) for i in (1, 3, 5)] + [255]


def _box(size, centre, yaw, colour):
    import trimesh
    T = trimesh.transformations.rotation_matrix(yaw, [0, 0, 1])
    T[:3, 3] = centre
    b = trimesh.creation.box(extents=size, transform=T)
    b.visual.face_colors = colour
    return b


def _slab(poly, z0, z1, colour):
    """A closed prism over a floor outline."""
    import mapbox_earcut as earcut
    import trimesh
    p = np.array(poly, float)
    if area(poly) < 0:
        p = p[::-1]
    n = len(p)
    tri = earcut.triangulate_float64(p, np.array([n], np.uint32)).reshape(-1, 3).astype(np.int64)
    V = np.vstack([np.column_stack([p, np.full(n, z1)]), np.column_stack([p, np.full(n, z0)])])
    i = np.arange(n)
    j = (i + 1) % n
    sides = np.vstack([np.column_stack([i + n, j + n, j]), np.column_stack([i + n, j, i])])
    m = trimesh.Trimesh(V, np.vstack([tri, tri[:, ::-1] + n, sides]), process=False)
    m.visual.face_colors = colour
    return m


def build_model(space):
    import trimesh
    parts = []
    for i, r in enumerate(space["rooms"]):
        if len(r["polygon"]) >= 3:
            parts.append(_slab(r["polygon"], -0.05, 0.0, _rgb(ROOM_COLORS[i % len(ROOM_COLORS)])))
    wall, glass = _rgb("#f4f2ed"), [156, 200, 238, 120]
    for w in space["walls"]:
        f = wall_frame(w)
        if f["L"] < 1e-3:
            continue
        t, H, h = w["thickness"], w["height"], w["thickness"] / 2

        def piece(u0, u1, z0, z1, thick=t, colour=wall):
            if u1 - u0 < 1e-3 or z1 - z0 < 1e-3:
                return
            c = along(w, f, (u0 + u1) / 2)
            parts.append(_box([u1 - u0, thick, z1 - z0], [c[0], c[1], (z0 + z1) / 2], f["angle"], colour))

        u = -h
        for o in wall_openings(space, w):
            if o["u0"] > u:
                piece(u, o["u0"], 0, H)
            top = min(H, o["sill"] + o["height"])
            piece(o["u0"], o["u1"], 0, o["sill"])
            piece(o["u0"], o["u1"], top, H)
            if o["type"] == "window":
                piece(o["u0"], o["u1"], o["sill"], top, 0.02, glass)
            u = max(u, o["u1"])
        if f["L"] + h > u:
            piece(u, f["L"] + h, 0, H)
    for o in space["objects"]:
        k = sum(ord(c) * 31 ** i for i, c in enumerate(reversed(str(o["label"])))) % (2 ** 32)
        parts.append(_box(o["size"], o["center"], o["yaw"], _rgb(FURN_COLORS[k % len(FURN_COLORS)])))
    if not parts:
        raise ValueError("this space has no floor plan to build a model from")
    m = trimesh.util.concatenate(parts)
    m.visual.vertex_colors = m.visual.vertex_colors   # per-vertex, which every format can carry
    return m


# ---------- floor plan for CAD ----------

def write_dxf(space, out: Path):
    import ezdxf
    from ezdxf.enums import TextEntityAlignment
    doc = ezdxf.new("R2010", setup=True)
    doc.units = ezdxf.units.M
    msp = doc.modelspace()
    for name, colour in [("WALLS", 7), ("WINDOWS", 5), ("DOORS", 3), ("ROOMS", 8), ("FURNITURE", 9), ("DIMENSIONS", 4), ("TEXT", 7)]:
        doc.layers.add(name, color=colour)
    quad = lambda w, f, u0, u1, h: [tuple(along(w, f, u0, -h)), tuple(along(w, f, u1, -h)), tuple(along(w, f, u1, h)), tuple(along(w, f, u0, h))]

    for r in space["rooms"]:
        msp.add_lwpolyline([tuple(p) for p in r["polygon"]], close=True, dxfattribs={"layer": "ROOMS"})
        c = centroid(r["polygon"])
        msp.add_text(r.get("name") or r["id"], height=0.18, dxfattribs={"layer": "TEXT"}) \
            .set_placement((c[0], c[1] + 0.08), align=TextEntityAlignment.MIDDLE_CENTER)
        msp.add_text(f"{abs(area(r['polygon'])):.1f} m2", height=0.13, dxfattribs={"layer": "TEXT"}) \
            .set_placement((c[0], c[1] - 0.18), align=TextEntityAlignment.MIDDLE_CENTER)
    for o in space["objects"]:
        sx, sy = o["size"][0] / 2, o["size"][1] / 2
        c, s = math.cos(o["yaw"]), math.sin(o["yaw"])
        pts = [(o["center"][0] + u * c - v * s, o["center"][1] + u * s + v * c) for u, v in [(-sx, -sy), (sx, -sy), (sx, sy), (-sx, sy)]]
        msp.add_lwpolyline(pts, close=True, dxfattribs={"layer": "FURNITURE"})
    for w in space["walls"]:
        f = wall_frame(w)
        h = w["thickness"] / 2
        ops = wall_openings(space, w)
        u = -h
        solid = []
        for o in ops:
            if o["u0"] > u:
                solid.append((u, o["u0"]))
            u = max(u, o["u1"])
        if f["L"] + h > u:
            solid.append((u, f["L"] + h))
        for u0, u1 in solid:
            msp.add_lwpolyline(quad(w, f, u0, u1, h), close=True, dxfattribs={"layer": "WALLS"})
        for o in ops:
            if o["type"] == "window":
                msp.add_lwpolyline(quad(w, f, o["u0"], o["u1"], h), close=True, dxfattribs={"layer": "WINDOWS"})
                msp.add_line(tuple(along(w, f, o["u0"])), tuple(along(w, f, o["u1"])), dxfattribs={"layer": "WINDOWS"})
            else:
                target = o.get("swing") or (w["rooms"][0] if w["rooms"] else None)
                side = room_side(space, w, target) if target else 1
                at_start = o.get("hinge") != "b"
                width = o["u1"] - o["u0"]
                hinge = along(w, f, o["u0"] if at_start else o["u1"], side * h)
                opened = f["n"] * side
                closed = f["d"] * (1 if at_start else -1)
                msp.add_line(tuple(hinge), tuple(hinge + opened * width), dxfattribs={"layer": "DOORS"})
                a0, a1 = (math.degrees(math.atan2(v[1], v[0])) for v in (opened, closed))
                if opened[0] * closed[1] - opened[1] * closed[0] < 0:
                    a0, a1 = a1, a0
                msp.add_arc(tuple(hinge), width, a0, a1, dxfattribs={"layer": "DOORS"})
        if f["L"] >= 0.2:
            side = outward_side(space, w)
            off = (side if side is not None else 1) * (h + (0.45 if side is not None else 0.25))
            dim = msp.add_aligned_dim(p1=tuple(along(w, f, 0)), p2=tuple(along(w, f, f["L"])), distance=off, dimstyle="EZDXF",
                                      override={"dimtxt": 0.12, "dimasz": 0.08, "dimexo": 0.04, "dimexe": 0.05, "dimdec": 2, "dimgap": 0.04},
                                      dxfattribs={"layer": "DIMENSIONS"})
            dim.render()
    doc.saveas(out)


# ---------- raw capture ----------

RAW_README = """Roomprint raw capture, nerfstudio layout.

images/      camera photos (JPEG), five a second, taken while tracking was good
depth/       LiDAR depth for the same moments: 16-bit PNG, millimetres, 0 = no reading,
             scaled up (nearest) to the photo's size
confidence/  ARKit's confidence for each depth pixel: 0 low, 1 medium, 2 high (8-bit PNG)
transforms.json  intrinsics and camera-to-world pose per frame (OpenGL camera: looks down
             -z, y up). The world is the floor plan's: metres, z up, floor at z = 0, the
             same frame as the STL/PLY/LAS/DXF exports.
"""


def write_raw(d: Path, out: Path):
    import cv2
    from PIL import Image

    import fuse
    space = json.loads((d / "space.json").read_text())
    rgbd = max((d / "uploads").glob("*.rgbd"), key=lambda p: p.stat().st_mtime, default=None)
    if not rgbd or "lidar_frame" not in space:
        raise FileNotFoundError("this space has no depth recording")
    M = fuse.to_plan(space["lidar_frame"])
    frames = []
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        z.writestr("README.txt", RAW_README)
        for i, ((h, depth, conf, _), (_, jpeg)) in enumerate(zip(fuse.frames(rgbd), fuse.records(rgbd, jpeg=True))):
            name = f"frame_{i + 1:05d}"
            jw, jh = h["jw"], h["jh"]
            z.writestr(f"images/{name}.jpg", jpeg)
            mm = np.clip(np.nan_to_num(depth) * 1000, 0, 65535).astype(np.uint16)
            for folder, arr in (("depth", mm), ("confidence", conf)):
                buf = io.BytesIO()
                Image.fromarray(cv2.resize(arr, (jw, jh), interpolation=cv2.INTER_NEAREST)).save(buf, "PNG")
                z.writestr(f"{folder}/{name}.png", buf.getvalue())
            k = jw / h["iw"]
            K = h["K"]
            T = M @ np.array(h["T"], float).reshape(4, 4).T
            frames.append({"file_path": f"images/{name}.jpg", "depth_file_path": f"depth/{name}.png",
                           "fl_x": K[0] * k, "fl_y": K[4] * k, "cx": K[2] * k, "cy": K[5] * k, "w": jw, "h": jh,
                           "time": h["t"], "transform_matrix": T.tolist()})
        z.writestr("transforms.json", json.dumps({"camera_model": "OPENCV", "depth_unit_scale_factor": 0.001,
                                                  "orientation_override": "none", "frames": frames}, indent=1))


def run(d: Path, kind: str, fmt: str, out: Path, box=None):
    if fmt not in FORMATS.get(kind, ()):
        raise ValueError(f"no {fmt} export of {kind}")
    tmp = out.with_name("part-" + out.name)   # keeps the extension: some writers go by it
    name = kind if kind != "mesh" else "scan"
    if kind == "mesh":
        write_mesh(crop(load_scan(d), box), fmt, tmp, name)
    elif kind == "points":
        write_points(*scan_points(d, box), fmt, tmp)
    elif kind == "model":
        write_mesh(build_model(normalize(json.loads((d / "space.json").read_text()))), fmt, tmp, name)
    elif kind == "plan":
        write_dxf(normalize(json.loads((d / "space.json").read_text())), tmp)
    elif kind == "raw":
        write_raw(d, tmp)
    tmp.replace(out)


if __name__ == "__main__":
    if len(sys.argv) not in (5, 6):
        print(__doc__)
        sys.exit(2)
    sys.path.insert(0, str(Path(__file__).parent))
    box = np.array([float(x) for x in sys.argv[5].split(",")]) if len(sys.argv) == 6 else None
    try:
        run(Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4]), box)
    except (ValueError, FileNotFoundError) as e:
        print(e, file=sys.stderr)
        sys.exit(3)
