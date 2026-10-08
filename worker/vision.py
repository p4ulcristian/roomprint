"""Doors and windows from the video frames, read by a local vision model (Ollama).

The geometry pass guesses openings from holes in the point cloud, which misses closed
doors and glass. Here every wall is cut into pieces of at most 3 m; each piece is
projected into the three frames that see it most squarely, warped to a straight-on view
(so image x maps linearly to metres along the wall) and the model is asked where the
doors and windows are. An opening counts as sure when two of the three views agree;
one seen in a single view is kept but marked unsure, for the user to confirm.
"""
import base64
import json
import math
import os
import urllib.request

import cv2
import numpy as np

import layout

OLLAMA = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
MODEL = os.environ.get("ROOMPRINT_VLM", "gemma4:e4b")
PIECE = 3.0       # m of wall per question
OVERLAP = 0.4     # m shared by neighbouring pieces so an opening on a seam is seen whole
PX_PER_M = 160
VIEWS = 3         # frames asked per piece; two agreeing make an opening sure

PROMPT = """This picture is a straight-on view of one section of a wall inside a home, \
{w:.1f} m wide and {h:.1f} m tall, floor at the bottom edge. Black areas were not filmed. \
Find the doors, open doorways and windows in this wall. Mirrors, TV screens, pictures and \
cupboard doors are not openings. For each opening give its type ("door" for doors and \
doorways, "window" for windows) and its left, right, top and bottom edges as fractions of \
the picture (0 = left/top edge, 1 = right/bottom edge). Use an empty list if there are none."""

SCHEMA = {
    "type": "object",
    "properties": {"openings": {"type": "array", "items": {
        "type": "object",
        "properties": {"type": {"type": "string", "enum": ["door", "window"]},
                       "left": {"type": "number"}, "right": {"type": "number"},
                       "top": {"type": "number"}, "bottom": {"type": "number"}},
        "required": ["type", "left", "right", "top", "bottom"]}}},
    "required": ["openings"],
}


def available() -> bool:
    try:
        with urllib.request.urlopen(f"{OLLAMA}/api/tags", timeout=5) as r:
            return any(m["name"] == MODEL for m in json.load(r)["models"])
    except Exception:
        return False


def _post(path, body, timeout=180):
    req = urllib.request.Request(f"{OLLAMA}{path}", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def ask(img: np.ndarray, w: float, h: float) -> list[dict]:
    ok, png = cv2.imencode(".png", img)
    res = _post("/api/chat", {
        "model": MODEL, "stream": False, "think": True, "format": SCHEMA, "keep_alive": "2m",
        "options": {"temperature": 0},
        "messages": [{"role": "user", "content": PROMPT.format(w=w, h=h),
                      "images": [base64.b64encode(png.tobytes()).decode()]}],
    })
    return json.loads(res["message"]["content"]).get("openings", [])


def unload():
    try:
        _post("/api/generate", {"model": MODEL, "keep_alive": 0}, timeout=30)
    except Exception:
        pass


def _project(K, Rcw, C, X):
    Xc = (X - C) @ Rcw  # world -> camera (Rcw is camera-to-world)
    z = Xc[:, 2]
    uv = (Xc[:, :2] / np.maximum(z, 1e-6)[:, None]) * [K[0, 0], K[1, 1]] + [K[0, 2], K[1, 2]]
    return uv, z


def best_views(quad_w, centre_w, normal_w, rec, img_size, n=2, min_gap=3):
    """Frames that see the wall piece whole-ish and squarely, best first, `min_gap` apart."""
    W, H = img_size
    frame_poly = np.array([[0, 0], [W, 0], [W, H], [0, H]], np.float32)
    scored = []
    for i in range(len(rec.cam_centers)):
        uv, z = _project(rec.intr[i], rec.cam_rots[i], rec.cam_centers[i], quad_w)
        if (z < 0.3).any():
            continue
        to_cam = rec.cam_centers[i] - centre_w
        dist = np.linalg.norm(to_cam)
        facing = abs(to_cam @ normal_w) / max(dist, 1e-9)
        if facing < 0.35:
            continue
        hull = cv2.convexHull(uv.astype(np.float32))
        area = cv2.contourArea(hull)
        if area < 1:
            continue
        inter, _ = cv2.intersectConvexConvex(hull, frame_poly)
        seen = inter / area
        if seen < 0.55:
            continue
        cover = min(1.0, inter / (W * H * 0.35))
        scored.append((seen * facing * cover, i, uv))
    scored.sort(key=lambda t: -t[0])
    picked = []
    for sc, i, uv in scored:
        if all(abs(i - j) >= min_gap for _, j, _ in picked):
            picked.append((sc, i, uv))
        if len(picked) == n:
            break
    return picked


def _interval_iou(a, b):
    inter = max(0.0, min(a[1], b[1]) - max(a[0], b[0]))
    union = max(a[1], b[1]) - min(a[0], b[0])
    return inter / union if union > 0 else 0.0


def _plausible(o):
    w = o["x1"] - o["x0"]
    if o["type"] == "door":
        return 0.55 <= w <= 2.6 and o["z0"] < 0.35 and o["z1"] > 1.6
    return 0.3 <= w <= 3.5 and 0.1 <= o["z0"] <= 1.7 and o["z1"] - o["z0"] >= 0.3


def vote(per_view):
    """Group detections from different views by type and overlap along the wall. A group
    seen in two or more views is sure; one seen once is kept, unsure, for the user to judge."""
    groups = []
    for vi, dets in enumerate(per_view):
        for d in dets:
            g = next((g for g in groups if g[0]["type"] == d["type"] and vi not in {v for v, _ in g[1]}
                      and _interval_iou((g[0]["x0"], g[0]["x1"]), (d["x0"], d["x1"])) >= 0.3), None)
            if g:
                g[1].append((vi, d))
                g[0].update({k: float(np.mean([e[k] for _, e in g[1]])) for k in ("x0", "x1", "z0", "z1")})
            else:
                groups.append([dict(d), [(vi, d)]])
    return [dict(g[0], sure=len(g[1]) >= 2) for g in groups]


def detect(space, view, rec, frame_paths, progress=lambda p, s: None) -> list[dict]:
    """Openings (space.json shape, without ids) found by the vision model."""
    imgs = {}

    def frame(i):
        if i not in imgs:
            imgs[i] = cv2.imread(str(frame_paths[i]))
        return imgs[i]

    h0 = frame(0).shape
    img_size = (h0[1], h0[0])
    walls = space["walls"]
    found = []
    for wi, w in enumerate(walls):
        a, b = np.array(w["a"], float), np.array(w["b"], float)
        L = float(np.linalg.norm(b - a))
        if L < 0.5:
            continue
        u = (b - a) / L
        Hw = w["height"]
        n_pieces = max(1, math.ceil((L - OVERLAP) / (PIECE - OVERLAP)))
        step = (L - PIECE) / (n_pieces - 1) if n_pieces > 1 else 0
        hits = []
        for k in range(n_pieces):
            s0 = k * step if n_pieces > 1 else 0.0
            s1 = min(L, s0 + PIECE) if n_pieces > 1 else L
            A, B = a + u * s0, a + u * s1
            corners = np.array([[*A, Hw], [*B, Hw], [*B, 0], [*A, 0]])  # TL TR BR BL seen from one side
            quad_w = layout.space_to_world(view, corners)
            centre_w = quad_w.mean(0)
            normal_w = np.cross(quad_w[1] - quad_w[0], quad_w[3] - quad_w[0])
            normal_w /= np.linalg.norm(normal_w)
            views = best_views(quad_w, centre_w, normal_w, rec, img_size, n=VIEWS)
            per_view = []
            for _, fi, uv in views:
                flip = uv[0, 0] > uv[1, 0]  # seen from the other side: A is on the right
                src = uv[[1, 0, 3, 2]] if flip else uv
                ow, oh = int((s1 - s0) * PX_PER_M), int(Hw * PX_PER_M)
                dst = np.array([[0, 0], [ow, 0], [ow, oh], [0, oh]], np.float32)
                M = cv2.getPerspectiveTransform(src.astype(np.float32), dst)
                flat = cv2.warpPerspective(frame(fi), M, (ow, oh), borderValue=(0, 0, 0))
                try:
                    raw = ask(flat, s1 - s0, Hw)
                except Exception as e:
                    print(f"  vision: wall {w['id']} frame {fi}: {e}", flush=True)
                    continue
                dets = []
                for o in raw:
                    l, r = sorted((float(o["left"]), float(o["right"])))
                    t, bt = sorted((float(o["top"]), float(o["bottom"])))
                    l, r, t, bt = (min(1.0, max(0.0, v)) for v in (l, r, t, bt))
                    x0, x1 = ((s1 - r * (s1 - s0), s1 - l * (s1 - s0)) if flip
                              else (s0 + l * (s1 - s0), s0 + r * (s1 - s0)))
                    d = {"type": o["type"], "x0": x0, "x1": x1, "z0": Hw * (1 - bt), "z1": Hw * (1 - t)}
                    if _plausible(d):
                        dets.append(d)
                per_view.append(dets)
            hits += vote(per_view)
        # pieces overlap: join hits of the same type that overlap along the wall
        hits.sort(key=lambda d: d["x0"])
        merged = []
        for d in hits:
            last = next((m for m in reversed(merged) if m["type"] == d["type"]), None)
            if last and d["x0"] < last["x1"] - 0.1:
                last.update(x1=max(last["x1"], d["x1"]), z0=min(last["z0"], d["z0"]),
                            z1=max(last["z1"], d["z1"]), sure=last["sure"] or d["sure"])
            else:
                merged.append(dict(d))
        for d in merged:
            x0, x1 = max(0.0, d["x0"]), min(L, d["x1"])
            if d["type"] == "door":
                found.append({"type": "door", "wall": w["id"], "offset": round(x0, 3),
                              "width": round(x1 - x0, 3), "height": round(min(max(d["z1"], 1.9), 2.4), 3),
                              "sill": 0.0, "source": "vision", "sure": d["sure"]})
            else:
                found.append({"type": "window", "wall": w["id"], "offset": round(x0, 3),
                              "width": round(x1 - x0, 3), "height": round(d["z1"] - d["z0"], 3),
                              "sill": round(d["z0"], 3), "source": "vision", "sure": d["sure"]})
        progress((wi + 1) / len(walls), f"looking for doors and windows (wall {wi + 1} of {len(walls)})")
    return found


def apply(space, found):
    """Keep the doorways between rooms, swap the hole-based guesses for what the model saw."""
    keep = [o for o in space["openings"] if o.get("source") != "gap"]
    for o in found:
        clash = any(k["wall"] == o["wall"] and
                    _interval_iou((k["offset"], k["offset"] + k["width"]),
                                  (o["offset"], o["offset"] + o["width"])) > 0.1 for k in keep)
        if not clash:
            keep.append(o)
    space["openings"] = [dict(o, id=f"o{i + 1}") for i, o in enumerate(keep)]
    return space
