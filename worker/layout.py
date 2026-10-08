"""Point cloud -> space.json (rooms, walls, doors, windows, furniture boxes).

Plain geometry, no learned layout model:
  1. level the cloud (camera up vector, then the floor plane), floor at z = 0
  2. provisional metric scale from the phone's height above the floor (~1.35 m)
  3. rotate so the walls run along x/y (most indoor walls are at right angles)
  4. rasterise to a 5 cm grid: floor cells, vertical-structure (wall) cells
  5. interior = floor + where the camera walked, minus walls; split into rooms at
     narrow passages (doorways) with a distance-transform watershed
  6. room outlines -> a rectangle pushed out to the walls when the room fills most of
     its bounding box, else a right-angled polygon -> walls (shared walls found by
     pairing facing edges) -> gaps in each wall become doors or windows (vision.py
     replaces the gap guesses when the vision model is available)
  7. leftover clusters inside rooms become furniture boxes
  8. rescale to the user's wall measurement if given
"""
import math

import cv2
import numpy as np
from scipy import ndimage
from skimage.segmentation import watershed

CELL = 0.05
PHONE_HEIGHT = 1.35
DEFAULT_CEILING = 2.6
EXT_WALL = 0.2
FACE_FIX = 1.5 * CELL
RECT_FILL = 0.6      # room mask must cover this much of its bounding box to be a rectangle...
INNER_WALL = 1.0     # ...and no straight wall run this long may cross its inside (an L-shape's corner)
WALL_SEARCH = 0.8    # how far past the floor a rectangle side may move out to reach its wall


# ---------- levelling and scale ----------

def rot_between(a, b):
    a, b = a / np.linalg.norm(a), b / np.linalg.norm(b)
    v, c = np.cross(a, b), float(a @ b)
    if np.linalg.norm(v) < 1e-9:
        return np.eye(3) if c > 0 else np.diag([1, -1, -1])
    vx = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + vx + vx @ vx * (1 / (1 + c))


def z_peaks(z, cam_z):
    """Floor = lowest strong z-histogram peak below the cameras; ceiling = highest above."""
    lo, hi = np.percentile(z, [0.5, 99.5])
    hist, edges = np.histogram(z, bins=300, range=(lo, hi))
    hist = ndimage.uniform_filter1d(hist.astype(float), 3)
    mid = (edges[:-1] + edges[1:]) / 2
    below, above = mid < cam_z, mid > cam_z
    floor = ceil = None
    if below.any():
        hb = np.where(below, hist, 0)
        strong = np.where(hb > 0.35 * hb.max())[0]
        floor = mid[strong.min()]
    if above.any():
        ha = np.where(above, hist, 0)
        if ha.max() > 0.15 * (hist[below].max() if below.any() else ha.max()):
            strong = np.where(ha > 0.35 * ha.max())[0]
            ceil = mid[strong.max()]
    return floor, ceil


def level(points, cams, rots):
    up = -rots[:, :, 1].mean(0)  # OpenCV camera y points down
    R = rot_between(up, np.array([0.0, 0, 1]))
    P, C = points @ R.T, cams @ R.T
    floor, _ = z_peaks(P[:, 2], np.median(C[:, 2]))
    if floor is not None:
        band = P[np.abs(P[:, 2] - floor) < 0.02 * (np.median(C[:, 2]) - floor + 1e-6) * 3]
        if len(band) > 500:
            band = band[np.random.default_rng(0).choice(len(band), min(len(band), 50000), replace=False)]
            mu = band.mean(0)
            n = np.linalg.svd(band - mu)[2][2]
            n = n if n[2] > 0 else -n
            if n[2] > math.cos(math.radians(15)):
                R2 = rot_between(n, np.array([0.0, 0, 1]))
                P, C, R = P @ R2.T, C @ R2.T, R2 @ R
    return P, C, R


def manhattan_angle(xy):
    def score(a):
        c, s = math.cos(a), math.sin(a)
        x = xy[:, 0] * c + xy[:, 1] * s
        y = -xy[:, 0] * s + xy[:, 1] * c
        sc = 0.0
        for v in (x, y):
            h, _ = np.histogram(v, bins=max(10, int((v.max() - v.min()) / CELL)))
            h = h / h.sum()
            sc += (h ** 2).sum()
        return sc
    coarse = np.radians(np.arange(0, 90, 0.5))
    best = max(coarse, key=score)
    fine = best + np.radians(np.arange(-0.5, 0.5, 0.05))
    return max(fine, key=score)


# ---------- polygons ----------

def _signed_area(poly):
    x, y = poly[:, 0], poly[:, 1]
    return 0.5 * (x @ np.roll(y, -1) - y @ np.roll(x, -1))


def _intersect(l1, l2):
    def abc(l):
        if l["t"] == "h":
            return 0.0, 1.0, l["c"]
        if l["t"] == "v":
            return 1.0, 0.0, l["c"]
        (x1, y1), (x2, y2) = l["p"], l["q"]
        a, b = y2 - y1, x1 - x2
        return a, b, a * x1 + b * y1
    a1, b1, c1 = abc(l1)
    a2, b2, c2 = abc(l2)
    det = a1 * b2 - a2 * b1
    if abs(det) < 1e-9:
        return np.array(l1["q"], float)
    return np.array([(c1 * b2 - c2 * b1) / det, (a1 * c2 - a2 * c1) / det])


def straighten(poly, snap_deg=12, merge=0.12, min_edge=0.12):
    """Snap near-axis edges to exact x/y lines, merge small jogs, re-intersect corners."""
    lines = []
    n = len(poly)
    for i in range(n):
        p, q = poly[i], poly[(i + 1) % n]
        d = q - p
        L = float(np.hypot(*d))
        if L < 1e-6:
            continue
        ang = math.degrees(math.atan2(d[1], d[0])) % 180
        if ang < snap_deg or ang > 180 - snap_deg:
            lines.append({"t": "h", "c": (p[1] + q[1]) / 2, "w": L, "p": p, "q": q})
        elif abs(ang - 90) < snap_deg:
            lines.append({"t": "v", "c": (p[0] + q[0]) / 2, "w": L, "p": p, "q": q})
        else:
            lines.append({"t": "g", "c": 0, "w": L, "p": p, "q": q})

    def verts_of(ls):
        return np.array([_intersect(ls[k - 1], ls[k]) for k in range(len(ls))])

    for _ in range(6):
        # merge neighbouring lines on (almost) the same axis line
        merged = True
        while merged and len(lines) > 3:
            merged = False
            for i in range(len(lines)):
                a, b = lines[i], lines[(i + 1) % len(lines)]
                if a["t"] == b["t"] and a["t"] in "hv" and abs(a["c"] - b["c"]) < merge:
                    w = a["w"] + b["w"]
                    lines[i] = dict(a, c=(a["c"] * a["w"] + b["c"] * b["w"]) / w, w=w, q=b["q"])
                    del lines[(i + 1) % len(lines)]
                    merged = True
                    break
        # parallel neighbours further apart get a perpendicular step between them
        out = []
        for i in range(len(lines)):
            a, b = lines[i], lines[(i + 1) % len(lines)]
            out.append(a)
            if a["t"] == b["t"] and a["t"] in "hv":
                corner = (np.asarray(a["q"]) + np.asarray(b["p"])) / 2
                out.append({"t": "v" if a["t"] == "h" else "h",
                            "c": corner[0] if a["t"] == "h" else corner[1],
                            "w": abs(a["c"] - b["c"]), "p": corner, "q": corner})
        lines = out
        if len(lines) < 3:
            break
        v = verts_of(lines)
        short = [np.linalg.norm(v[(k + 1) % len(lines)] - v[k]) < min_edge for k in range(len(lines))]
        if not any(short) or len(lines) - sum(short) < 3:
            break
        lines = [l for l, sh in zip(lines, short) if not sh]
    if len(lines) < 3:
        return poly
    verts = np.array([_intersect(lines[k - 1], lines[k]) for k in range(len(lines))])
    # remove collinear / duplicate vertices
    clean = []
    for k in range(len(verts)):
        a, b, c = verts[k - 1], verts[k], verts[(k + 1) % len(verts)]
        if np.linalg.norm(b - a) < 1e-3:
            continue
        cr = (b - a)[0] * (c - b)[1] - (b - a)[1] * (c - b)[0]
        if abs(cr) < 1e-4:
            continue
        clean.append(b)
    return np.array(clean) if len(clean) >= 3 else verts


def offset_poly(poly, d):
    """Move every edge of a CCW polygon outward by d and re-intersect the corners."""
    n = len(poly)
    lines = []
    for i in range(n):
        p, q = poly[i], poly[(i + 1) % n]
        u = (q - p) / max(np.linalg.norm(q - p), 1e-9)
        nrm = np.array([u[1], -u[0]])
        lines.append({"t": "g", "c": 0, "p": p + nrm * d, "q": q + nrm * d})
    return np.array([_intersect(lines[k - 1], lines[k]) for k in range(n)])


# ---------- room outlines ----------

def _longest_run(line):
    best = cur = 0
    for v in line:
        cur = cur + 1 if v else 0
        best = max(best, cur)
    return best


def rect_to_walls(m, wall_mask):
    """Axis-aligned rectangle (cell bounds x0, x1, y0, y1, inclusive) of a room mask, or
    None when the room is not a rectangle. Furniture takes bites out of the floor, so the
    fill threshold is loose; what rules a rectangle out is a long straight wall inside it.
    Each side is then pushed out past the furniture to the strongest wall line in reach."""
    ys, xs = np.nonzero(m)
    x0, x1 = (int(v) for v in np.percentile(xs, [1, 99]).round())
    y0, y1 = (int(v) for v in np.percentile(ys, [1, 99]).round())
    if x1 - x0 < 4 or y1 - y0 < 4 or m[y0:y1 + 1, x0:x1 + 1].mean() < RECT_FILL:
        return None
    margin = int(0.7 / CELL)
    inner = wall_mask[y0 + margin:y1 + 1 - margin, x0 + margin:x1 + 1 - margin]
    run = int(INNER_WALL / CELL)
    if inner.size and any(_longest_run(line) >= run for line in (*inner, *inner.T)):
        return None
    Hh, W = wall_mask.shape
    reach = int(WALL_SEARCH / CELL)

    def push(edge, step, line):
        cov = []
        for k in range(1, reach + 1):
            c = edge + step * k
            if not 0 <= c < (W if line == "col" else Hh):
                break
            seg = wall_mask[y0:y1 + 1, c] if line == "col" else wall_mask[c, x0:x1 + 1]
            cov.append(seg.mean())
        if not cov or max(cov) < 0.3:
            return edge
        k = int(np.argmax(cov))
        while k > 0 and cov[k - 1] >= 0.5 * cov[int(np.argmax(cov))]:
            k -= 1
        return edge + step * k  # last floor cell before the wall's inner face

    return push(x0, -1, "col"), push(x1, 1, "col"), push(y0, -1, "row"), push(y1, 1, "row")


def right_angled(m):
    """Outline of a non-rectangular room with every edge on x or y (the cloud is already
    rotated so walls run along the axes); notches narrower than 0.6 m are filled."""
    k = int(0.6 / CELL)
    mm = ndimage.binary_closing(np.pad(m, k), np.ones((k, k)))[k:-k, k:-k] | m
    cs, _ = cv2.findContours(mm.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    cnt = max(cs, key=cv2.contourArea)
    return cv2.approxPolyDP(cnt, 0.15 / CELL, True)[:, 0, :]


# ---------- main ----------

def build(rec, wall_length_m=None, room_names=None, progress=lambda p, s: None):
    rng = np.random.default_rng(0)
    keep = rec.conf >= np.percentile(rec.conf, 35)
    P, colors = rec.points[keep].astype(np.float64), rec.colors[keep]

    P, C, R_level = level(P, rec.cam_centers, rec.cam_rots)
    progress(0.1, "levelling")
    floor, ceil = z_peaks(P[:, 2], np.median(C[:, 2]))
    if floor is None:
        floor = np.percentile(P[:, 2], 2)
    cam_h = np.median(C[:, 2]) - floor
    s = PHONE_HEIGHT / cam_h
    P = (P - [0, 0, floor]) * s
    C = (C - [0, 0, floor]) * s
    H = (ceil - floor) * s if ceil is not None else DEFAULT_CEILING
    if not 2.1 < H < 4.0:
        H = DEFAULT_CEILING

    band = P[(P[:, 2] > 0.5) & (P[:, 2] < H - 0.35)]
    sub = band[rng.choice(len(band), min(len(band), 200000), replace=False)]
    ang = manhattan_angle(sub[:, :2])
    c, sn = math.cos(ang), math.sin(ang)
    Rz = np.array([[c, sn, 0], [-sn, c, 0], [0, 0, 1]])
    P, C = P @ Rz.T, C @ Rz.T
    progress(0.25, "aligning walls")

    # ---- grid ----
    inside = (P[:, 2] > -0.15) & (P[:, 2] < H + 0.15)
    lo = np.percentile(P[inside, :2], 0.5, axis=0) - 0.5
    hi = np.percentile(P[inside, :2], 99.5, axis=0) + 0.5
    lo, hi = np.minimum(lo, C[:, :2].min(0) - 0.5), np.maximum(hi, C[:, :2].max(0) + 0.5)
    W, Hh = int((hi[0] - lo[0]) / CELL) + 1, int((hi[1] - lo[1]) / CELL) + 1

    def cells(xy):
        ij = np.floor((xy - lo) / CELL).astype(int)
        ok = (ij[:, 0] >= 0) & (ij[:, 0] < W) & (ij[:, 1] >= 0) & (ij[:, 1] < Hh)
        return ij, ok

    fl = P[np.abs(P[:, 2]) < 0.06]
    ij, ok = cells(fl[:, :2])
    floor_cnt = np.zeros((Hh, W), int)
    np.add.at(floor_cnt, (ij[ok, 1], ij[ok, 0]), 1)
    floor_mask = floor_cnt >= 2

    zb = np.arange(0.3, H - 0.25, 0.1)
    wb = P[(P[:, 2] > zb[0]) & (P[:, 2] < zb[-1] + 0.1)]
    ij, ok = cells(wb[:, :2])
    zi = np.clip(((wb[:, 2] - zb[0]) / 0.1).astype(int), 0, len(zb) - 1)
    occ = np.zeros((Hh, W, len(zb)), bool)
    occ[ij[ok, 1], ij[ok, 0], zi[ok]] = True
    vert = occ.sum(2) >= max(4, int(0.4 * len(zb)))
    wall_mask = ndimage.binary_opening(vert, np.ones((2, 2))) | vert & ndimage.binary_dilation(vert, iterations=1)
    wall_mask = ndimage.binary_dilation(wall_mask, iterations=1)

    traj = np.zeros((Hh, W), bool)
    ij, ok = cells(C[:, :2])
    traj[ij[ok, 1], ij[ok, 0]] = True
    traj = ndimage.binary_dilation(traj, iterations=int(0.25 / CELL))

    k = int(0.3 / CELL)
    interior = ndimage.binary_closing(floor_mask | traj, np.ones((k, k)))
    interior = ndimage.binary_fill_holes(interior) & ~wall_mask
    interior = ndimage.binary_opening(interior, np.ones((3, 3)))
    lab, nlab = ndimage.label(interior)
    if nlab == 0:
        raise RuntimeError("could not find any floor; was the floor in the video?")
    sizes = ndimage.sum(interior, lab, range(1, nlab + 1)) * CELL * CELL
    interior = np.isin(lab, 1 + np.where(sizes >= 1.5)[0])
    progress(0.4, "finding rooms")

    # ---- rooms ----
    dist = ndimage.distance_transform_edt(interior) * CELL
    seeds, ns = ndimage.label(dist > 0.47)
    if ns:
        ss = ndimage.sum(seeds > 0, seeds, range(1, ns + 1)) * CELL * CELL
        good = 1 + np.where(ss >= 0.5)[0]
        seeds = np.where(np.isin(seeds, good), seeds, 0)
    if not seeds.any():
        seeds = interior.astype(int)
    rooms_lab = watershed(-dist, seeds, mask=interior)

    def to_xy(colrow):
        return lo + (np.asarray(colrow, float) + 0.5) * CELL

    rooms = []
    for li in np.unique(rooms_lab):
        if li == 0:
            continue
        m = (rooms_lab == li).astype(np.uint8)
        area = m.sum() * CELL * CELL
        if area < 1.5:
            continue
        rect = rect_to_walls(m.astype(bool), wall_mask)
        if rect:
            x0, x1, y0, y1 = rect
            (ax, ay), (bx, by) = lo + np.array([x0, y0]) * CELL, lo + np.array([x1 + 1, y1 + 1]) * CELL
            poly = np.array([[ax, ay], [bx, ay], [bx, by], [ax, by]])
        else:
            poly = to_xy(right_angled(m.astype(bool)))
            if _signed_area(poly) < 0:
                poly = poly[::-1]
            poly = straighten(poly, snap_deg=45, merge=0.3, min_edge=0.4)
        if _signed_area(poly) < 0:
            poly = poly[::-1]
        # the dilated wall mask eats ~1.5 cells into the room; give it back
        poly = offset_poly(poly, FACE_FIX)
        if abs(_signed_area(poly)) < 1.0:
            continue
        rooms.append({"label": int(li), "poly": poly, "area": abs(_signed_area(poly))})
    rooms.sort(key=lambda r: -r["area"])
    for i, r in enumerate(rooms):
        r["id"] = f"r{i + 1}"
        r["name"] = (room_names[i] if room_names and i < len(room_names) else f"Room {i + 1}")
    progress(0.55, "building walls")

    # ---- walls ----
    edges = []
    for r in rooms:
        poly = r["poly"]
        n = len(poly)
        for i in range(n):
            p, q = poly[i], poly[(i + 1) % n]
            d = q - p
            L = float(np.hypot(*d))
            if L < 0.05:
                continue
            u = d / L
            prev = poly[i - 1]
            nxt = poly[(i + 2) % n]
            # convex corner at p/q (CCW polygon: left turn = convex)
            cvx_p = ((p - prev)[0] * u[1] - (p - prev)[1] * u[0]) < 0
            cvx_q = (u[0] * (nxt - q)[1] - u[1] * (nxt - q)[0]) > 0
            edges.append({"room": r["id"], "p": p, "u": u, "L": L, "n": np.array([u[1], -u[0]]),
                          "cvx": (cvx_p, cvx_q), "free": [(0.0, L)]})

    def subtract(intervals, a, b):
        out = []
        for x, y in intervals:
            if b <= x or a >= y:
                out.append((x, y))
                continue
            if a > x:
                out.append((x, a))
            if b < y:
                out.append((b, y))
        return [(x, y) for x, y in out if y - x > 0.02]

    walls = []
    for i, e1 in enumerate(edges):
        for e2 in edges[i + 1:]:
            if e1["room"] == e2["room"] or e1["n"] @ e2["n"] > -0.97:
                continue
            gap = (e2["p"] - e1["p"]) @ e1["n"]
            if not 0.02 < gap < 0.5:
                continue
            a2 = (e2["p"] - e1["p"]) @ e1["u"]
            b2 = (e2["p"] + e2["u"] * e2["L"] - e1["p"]) @ e1["u"]
            a, b = max(0.0, min(a2, b2)), min(e1["L"], max(a2, b2))
            if b - a < 0.3:
                continue
            t = max(gap, 0.08)
            mid = e1["p"] + e1["n"] * gap / 2
            walls.append({"a": mid + e1["u"] * a, "b": mid + e1["u"] * b, "thickness": t,
                          "rooms": [e1["room"], e2["room"]]})
            e1["free"] = subtract(e1["free"], a, b)
            o1, o2 = (mid + e1["u"] * a - e2["p"]) @ e2["u"], (mid + e1["u"] * b - e2["p"]) @ e2["u"]
            e2["free"] = subtract(e2["free"], min(o1, o2), max(o1, o2))
    for e in edges:
        for a, b in e["free"]:
            if b - a < 0.1:
                continue
            t = EXT_WALL
            if a < 1e-6:
                a -= t / 2 if e["cvx"][0] else -t / 2
            if b > e["L"] - 1e-6:
                b += t / 2 if e["cvx"][1] else -t / 2
            if b - a < 0.1:
                continue
            base = e["p"] + e["n"] * t / 2
            walls.append({"a": base + e["u"] * a, "b": base + e["u"] * b, "thickness": t, "rooms": [e["room"]]})
    progress(0.7, "finding doors and windows")

    # ---- openings ----
    openings = []
    label_of_room = {r["label"]: r["id"] for r in rooms}

    def wall_frame(w):
        d = w["b"] - w["a"]
        L = float(np.hypot(*d))
        return d / max(L, 1e-9), L

    # Doorways between rooms: where two watershed labels touch, the floor runs on.
    for la, ra in label_of_room.items():
        for lb, rb in label_of_room.items():
            if lb <= la:
                continue
            ma, mb = rooms_lab == la, rooms_lab == lb
            touch = ma & (ndimage.binary_dilation(mb, structure=ndimage.generate_binary_structure(2, 1)))
            if touch.sum() < 0.4 / CELL:
                continue
            ys, xs = np.nonzero(touch)
            pts2 = to_xy(np.stack([xs, ys], 1))
            ctr = pts2.mean(0)
            best = None
            for wi, w in enumerate(walls):
                if set(w["rooms"]) != {ra, rb}:
                    continue
                u, L = wall_frame(w)
                along = (ctr - w["a"]) @ u
                perp = abs((ctr - w["a"]) @ np.array([u[1], -u[0]]))
                if -0.3 < along < L + 0.3 and perp < 0.5 and (best is None or perp < best[0]):
                    best = (perp, wi, u, L)
            if best is None:
                continue
            _, wi, u, L = best
            proj = (pts2 - walls[wi]["a"]) @ u
            width = float(np.clip(proj.max() - proj.min() + CELL + 2 * FACE_FIX, 0.6, min(2.5, L)))
            off = float(np.clip(proj.mean() - width / 2, 0, L - width))
            openings.append({"type": "door", "wall": wi, "offset": off, "width": width,
                             "height": 2.05, "sill": 0.0, "source": "doorway"})
    for wi, w in enumerate(walls):
        a, b = w["a"], w["b"]
        d = b - a
        L = float(np.hypot(*d))
        if L < 0.6:
            continue
        u = d / L
        nrm = np.array([u[1], -u[0]])
        rel = P[:, :2] - a
        along, perp = rel @ u, rel @ nrm
        near = (np.abs(perp) < w["thickness"] / 2 + 0.12) & (along > -0.05) & (along < L + 0.05)
        Q = P[near]
        qa = along[near]
        nb, nz = int(L / CELL) + 1, int(H / 0.1) + 1
        grid = np.zeros((nb, nz), bool)
        ai = np.clip((qa / CELL).astype(int), 0, nb - 1)
        zi2 = np.clip((Q[:, 2] / 0.1).astype(int), 0, nz - 1)
        grid[ai, zi2] = True
        zc = (np.arange(nz) + 0.5) * 0.1

        def frac(zlo, zhi, cols):
            m = (zc > zlo) & (zc < zhi)
            return grid[cols][:, m].mean() if m.any() and len(cols) else 0.0

        midband = (zc > 1.0) & (zc < 1.8)
        col_empty = grid[:, midband].mean(1) < 0.2
        runs, start = [], None
        for k2, e in enumerate(np.append(col_empty, False)):
            if e and start is None:
                start = k2
            elif not e and start is not None:
                runs.append((start, k2))
                start = None
        behind = (perp > w["thickness"] / 2 + 0.2) if len(w["rooms"]) == 1 else None
        taken = [(o["offset"], o["offset"] + o["width"]) for o in openings if o["wall"] == wi]
        for r0, r1 in runs:
            width = (r1 - r0) * CELL
            if any(r0 * CELL < b2 and r1 * CELL > a2 for a2, b2 in taken):
                continue
            if width < 0.5 or width > 3.0 or r0 < 2 or r1 > nb - 2:
                continue
            cols = np.arange(r0, r1)
            sides = np.r_[np.arange(max(0, r0 - 4), r0), np.arange(r1, min(nb, r1 + 4))]
            if frac(1.0, 1.8, sides) < 0.4:
                continue  # wall either side not seen: probably just unobserved
            low = frac(0.1, 0.7, cols)
            lintel = frac(2.15, H - 0.1, cols) if H > 2.4 else 1.0
            seen_behind = True
            if behind is not None:
                m = behind & (along > r0 * CELL) & (along < r1 * CELL)
                seen_behind = m.sum() > 50
            if low < 0.25 and (len(w["rooms"]) == 2 or seen_behind or lintel > 0.3):
                top = 2.05
                for zz in np.arange(1.8, H, 0.1):
                    if frac(zz, zz + 0.1, cols) > 0.5:
                        top = float(np.clip(zz, 1.9, 2.4))
                        break
                openings.append({"type": "door", "wall": wi, "offset": r0 * CELL, "width": width,
                                 "height": top, "sill": 0.0, "source": "gap"})
            elif low >= 0.25 and (lintel > 0.3 or seen_behind):
                filled = [zz for zz in np.arange(0.1, 1.6, 0.1) if frac(zz, zz + 0.1, cols) > 0.3]
                sill = float(np.clip((max(filled) + 0.1) if filled else 0.9, 0.3, 1.4))
                topw = 2.1
                for zz in np.arange(1.8, H, 0.1):
                    if frac(zz, zz + 0.1, cols) > 0.5:
                        topw = float(zz)
                        break
                openings.append({"type": "window", "wall": wi, "offset": r0 * CELL, "width": width,
                                 "height": max(0.4, topw - sill), "sill": sill, "source": "gap"})
    progress(0.8, "finding furniture")

    # ---- furniture ----
    wall_dist = ndimage.distance_transform_edt(~wall_mask) * CELL
    fp = P[(P[:, 2] > 0.08) & (P[:, 2] < min(2.2, H - 0.2))]
    ij, ok = cells(fp[:, :2])
    fp, ij = fp[ok], ij[ok]
    rr, cc = ij[:, 1], ij[:, 0]
    sel = (rooms_lab[rr, cc] > 0) & (wall_dist[rr, cc] > 0.12)
    fp, rr, cc = fp[sel], rr[sel], cc[sel]
    cnt = np.zeros((Hh, W), int)
    np.add.at(cnt, (rr, cc), 1)
    occf = ndimage.binary_closing(cnt >= 3, np.ones((3, 3)))
    occf = ndimage.binary_opening(occf, np.ones((2, 2)))
    flab, nf = ndimage.label(occf)
    objects = []
    pt_lab = flab[rr, cc]
    for fi in range(1, nf + 1):
        m = flab == fi
        area = m.sum() * CELL * CELL
        if area < 0.12:
            continue
        ys, xs = np.nonzero(m)
        (cx, cy), (sw, sh), angd = cv2.minAreaRect(np.stack([xs, ys], 1).astype(np.float32))
        zs = fp[pt_lab == fi, 2]
        if len(zs) < 30:
            continue
        h = float(np.percentile(zs, 90))
        if h < 0.15:
            continue
        sw, sh = (sw + 1) * CELL, (sh + 1) * CELL
        yaw = math.radians(angd)
        if abs(math.degrees(yaw) % 90) < 8 or abs(math.degrees(yaw) % 90) > 82:
            yaw = round(yaw / (math.pi / 2)) * (math.pi / 2)
        lo_side, hi_side = sorted((sw, sh))
        a2 = sw * sh
        if h > 1.5 and lo_side < 0.8:
            name = "wardrobe"
        elif h < 0.65 and a2 > 2.0:
            name = "bed"
        elif 0.78 <= h < 1.05 and hi_side > 1.4 and lo_side > 0.7:
            name = "sofa"
        elif 0.65 < h < 0.8 and a2 > 0.5:
            name = "table"
        elif a2 < 0.5 and h < 1.1:
            name = "chair"
        else:
            name = "object"
        center = to_xy([cx, cy])
        rl = rooms_lab[int(cy), int(cx)] if 0 <= int(cy) < Hh and 0 <= int(cx) < W else 0
        objects.append({"label": name, "room": label_of_room.get(int(rl)), "center": [center[0], center[1], h / 2],
                        "size": [sw, sh, h], "yaw": yaw})

    # ---- final scale + origin ----
    factor, source = 1.0, "guess"
    if wall_length_m and walls:
        longest = max(float(np.hypot(*(w["b"] - w["a"]))) for w in walls)
        factor, source = wall_length_m / longest, "measurement"
    allxy = np.concatenate([r["poly"] for r in rooms] + [np.array([w["a"], w["b"]]) for w in walls])
    origin = allxy.min(0) - 0.3 if len(allxy) else np.zeros(2)

    def X(p):
        return [round(float(v), 3) for v in ((np.asarray(p, float) - origin) * factor)]

    space = {
        "version": 1,
        "rooms": [{"id": r["id"], "name": r["name"], "polygon": [X(p) for p in r["poly"]],
                   "height": round(H * factor, 3)} for r in rooms],
        "walls": [{"id": f"w{i + 1}", "a": X(w["a"]), "b": X(w["b"]),
                   "thickness": round(w["thickness"] * factor, 3), "height": round(H * factor, 3),
                   "rooms": w["rooms"]} for i, w in enumerate(walls)],
        "openings": [{"id": f"o{i + 1}", "type": o["type"], "wall": f"w{o['wall'] + 1}",
                      "offset": round(o["offset"] * factor, 3), "width": round(o["width"] * factor, 3),
                      "height": round(o["height"] * factor, 3), "sill": round(o["sill"] * factor, 3),
                      "source": o["source"]}
                     for i, o in enumerate(openings)],
        "objects": [{"id": f"f{i + 1}", "label": o["label"], "room": o["room"],
                     "center": X(o["center"][:2]) + [round(o["center"][2] * factor, 3)],
                     "size": [round(v * factor, 3) for v in o["size"]], "yaw": round(o["yaw"], 4)}
                    for i, o in enumerate(objects)],
        "scale": {"source": source, "factor": round(float(s * factor), 6)},
    }
    Pf = P.copy()
    Pf[:, :2] = (Pf[:, :2] - origin) * factor
    Pf[:, 2] *= factor
    progress(0.9, "writing")
    # how to get from space.json coordinates back to the reconstruction's world (vision.py)
    view = {"R_level": R_level, "floor": float(floor), "s": float(s), "Rz": Rz,
            "origin": origin, "factor": float(factor)}
    return space, Pf.astype(np.float32), colors, view


def space_to_world(view, pts):
    """(N, 3) points in space.json coordinates -> the reconstruction's world frame."""
    p = np.asarray(pts, float).copy()
    p[:, :2] = p[:, :2] / view["factor"] + view["origin"]
    p[:, 2] /= view["factor"]
    p = p @ view["Rz"]                      # undo the wall alignment
    p = p / view["s"] + [0, 0, view["floor"]]
    return p @ view["R_level"]              # undo the levelling
