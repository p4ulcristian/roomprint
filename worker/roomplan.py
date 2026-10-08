"""RoomPlan scan (from the Roomprint iOS app) -> space.json. No GPU: LiDAR already
measured everything in metres, so this is only a change of coordinates.

The app writes its own plain JSON (ios/Sources/Roomprint/ScanExport.swift), not
RoomPlan's Codable encoding:

  {"version": 1, "rooms": [{"name": str|null, "floor": [[x,y,z], ...],
                            "sections": [{"label": str, "center": [x,y,z]}]}],
   "walls" | "doors" | "windows" | "openings": [{"id", "parent": id|null,
       "dimensions": [w, h, d], "transform": [16 floats, column-major]}],
   "objects": [{"category": str, "dimensions": [w, h, d], "transform": [...]}]}

RoomPlan is y-up and right-handed; space.json is z-up, so a RoomPlan point
(x, y, z) lands on the plan at (x, -z) at height y.
"""
import json
import math
from pathlib import Path

import numpy as np

INNER_WALL = 0.12
OUTER_WALL = 0.2
SECTION_NAMES = {"livingRoom": "Living room", "diningRoom": "Dining room", "bedroom": "Bedroom",
                 "bathroom": "Bathroom", "kitchen": "Kitchen"}


def _m(t):
    return np.array(t, float).reshape(4, 4).T  # column-major -> row-major 4x4


def _plan_raw(p):
    return np.array([p[0], -p[2]])


def _axis_raw(M):
    """The surface's local x axis (its width direction) on the plan."""
    x = M[:3, 0]
    v = np.array([x[0], -x[2]])
    return v / max(np.linalg.norm(v), 1e-9)


def _signed_area(poly):
    x, y = poly[:, 0], poly[:, 1]
    return 0.5 * (x @ np.roll(y, -1) - y @ np.roll(x, -1))


def _seg_dist(p, a, b):
    d = b - a
    t = np.clip((p - a) @ d / max(d @ d, 1e-12), 0, 1)
    return float(np.linalg.norm(p - (a + t * d)))


def _inside(pt, poly):
    x, y = pt
    inside = False
    for i in range(len(poly)):
        (x1, y1), (x2, y2) = poly[i - 1], poly[i]
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
            inside = not inside
    return inside


def _hull(pts):
    """Convex hull, counter-clockwise (monotone chain)."""
    pts = sorted(map(tuple, pts))

    def half(seq):
        out = []
        for p in seq:
            while len(out) >= 2 and ((out[-1][0] - out[-2][0]) * (p[1] - out[-2][1])
                                     - (out[-1][1] - out[-2][1]) * (p[0] - out[-2][0])) <= 0:
                out.pop()
            out.append(p)
        return out[:-1]
    return np.array(half(pts) + half(pts[::-1]))


SPLIT_CELL = 0.02   # m per pixel when cutting a floor along its walls
MIN_ROOM = 1.0      # m2; smaller pieces (wall stubs, alcoves) join their neighbour


def split_floor(poly, segs):
    """Cut a floor outline along the wall segments into rooms. Each piece grows back over
    the wall lines to the nearest piece, so neighbouring rooms meet at the wall centre."""
    import cv2
    from scipy import ndimage
    lo = poly.min(0) - 0.1
    size = np.ceil((poly.max(0) + 0.1 - lo) / SPLIT_CELL).astype(int)
    px = lambda p: np.round((np.asarray(p) - lo) / SPLIT_CELL).astype(np.int32)
    floor = np.zeros((size[1], size[0]), np.uint8)
    cv2.fillPoly(floor, [px(poly)], 1)
    cut = floor.copy()
    for a, b in segs:
        cv2.line(cut, tuple(px(a)), tuple(px(b)), 0, thickness=3)
    lab, n = ndimage.label(cut)
    areas = ndimage.sum(cut, lab, range(1, n + 1)) * SPLIT_CELL ** 2
    keep = [k + 1 for k in range(n) if areas[k] >= MIN_ROOM]
    if len(keep) <= 1:
        return [poly]
    lab = np.where(np.isin(lab, keep), lab, 0)
    # every other floor pixel (wall lines, small pieces) takes its nearest room's label
    _, (iy, ix) = ndimage.distance_transform_edt(lab == 0, return_indices=True)
    lab = np.where(floor > 0, lab[iy, ix], 0)
    out = []
    for k in keep:
        cs, _ = cv2.findContours((lab == k).astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        c = max(cs, key=cv2.contourArea)
        c = cv2.approxPolyDP(c, 0.05 / SPLIT_CELL, True)[:, 0, :] * SPLIT_CELL + lo
        if len(c) >= 3:
            # the plan is already turned to the axes: square off jogs where wall stubs end
            from layout import straighten
            if _signed_area(c) < 0:
                c = c[::-1]
            out.append(straighten(c, snap_deg=25, merge=0.1, min_edge=0.25))
    return out or [poly]


def convert(scan: dict, names: list[str | None] | None = None) -> dict:
    walls_in = scan.get("walls", [])

    # RoomPlan's world yaw is wherever the phone pointed at the start: turn the plan so
    # the walls run along x and y (length-weighted mean of the wall angles, mod 90 deg).
    acc = sum(w["dimensions"][0] * np.exp(4j * math.atan2(*_axis_raw(_m(w["transform"]))[::-1]))
              for w in walls_in) if walls_in else 0
    th = -np.angle(acc) / 4 if abs(acc) > 0 else 0.0
    R = np.array([[math.cos(th), -math.sin(th)], [math.sin(th), math.cos(th)]])

    def plan(p):
        return R @ _plan_raw(p)

    def axis(M):
        return R @ _axis_raw(M)

    floor_y = min((_m(w["transform"])[1, 3] - w["dimensions"][1] / 2 for w in walls_in), default=0.0)

    # ---- rooms: each scanned floor, split along the walls that cross it ----
    # One continuous walk through a flat comes back as a single RoomPlan room whose
    # sections say which parts are the kitchen, bathroom, ...; the inner walls cut it.
    segs = []
    for w in walls_in:
        M = _m(w["transform"])
        c, u = plan(M[:3, 3]), axis(M)
        segs.append((c - u * w["dimensions"][0] / 2, c + u * w["dimensions"][0] / 2))
    rooms = []
    for i, r in enumerate(scan.get("rooms", [])):
        pts = np.array([plan(p) for p in r.get("floor") or []])
        if len(pts) < 3:
            continue
        given = r.get("name") or (names[i] if names and i < len(names) else None)
        sections = [(plan(sec["center"]), SECTION_NAMES.get(sec["label"])) for sec in r.get("sections", [])]
        parts = split_floor(pts, segs)
        for poly in parts:
            if _signed_area(poly) < 0:
                poly = poly[::-1]
            labels = [l for c, l in sections if l and _inside(c, poly)]
            name = given if given and len(parts) == 1 else (labels[0] if labels else None)
            rooms.append({"id": f"r{len(rooms) + 1}", "name": name, "poly": poly})
    taken = {}
    for r in rooms:  # unnamed parts get numbers; repeated labels get "Bedroom 2"
        if not r["name"]:
            r["name"] = f"Room {r['id'][1:]}"
        taken[r["name"]] = taken.get(r["name"], 0) + 1
        if taken[r["name"]] > 1:
            r["name"] = f"{r['name']} {taken[r['name']]}"

    if not rooms and walls_in:
        # no floor outline came through: one room around all the walls
        pts = []
        for w in walls_in:
            M = _m(w["transform"])
            c, u = plan(M[:3, 3]), axis(M)
            pts += [c - u * w["dimensions"][0] / 2, c + u * w["dimensions"][0] / 2]
        rooms.append({"id": "r1", "name": (names or [None])[0] or "Room 1", "poly": _hull(np.array(pts))})

    # ---- walls ----
    walls, wall_ix = [], {}
    for w in walls_in:
        M = _m(w["transform"])
        c, u = plan(M[:3, 3]), axis(M)
        half = w["dimensions"][0] / 2
        a, b = c - u * half, c + u * half
        mid = (a + b) / 2
        near = [r["id"] for r in rooms
                if any(_seg_dist(mid, r["poly"][k - 1], r["poly"][k]) < 0.35 for k in range(len(r["poly"])))]
        wall_ix[w["id"]] = len(walls)
        if not near and rooms:
            near = [rooms[0]["id"]]
        t = INNER_WALL if len(near) > 1 else OUTER_WALL
        if len(near) == 1:
            # RoomPlan measures the inside face; push an outer wall's centre line outwards
            room = next(r for r in rooms if r["id"] == near[0])
            n = np.array([u[1], -u[0]])
            if (room["poly"].mean(0) - mid) @ n > 0:
                n = -n
            a, b = a + n * t / 2, b + n * t / 2
        walls.append({"a": a, "b": b, "height": w["dimensions"][1], "rooms": near, "thickness": t})

    # ---- doors, windows, openings: placed on their parent wall ----
    openings = []
    for kind, items in (("door", scan.get("doors", [])), ("window", scan.get("windows", [])),
                        ("door", scan.get("openings", []))):
        for o in items:
            M = _m(o["transform"])
            c = plan(M[:3, 3])
            wdt, hgt = o["dimensions"][0], o["dimensions"][1]
            wi = wall_ix.get(o.get("parent"))
            if wi is None and walls:
                wi = min(range(len(walls)), key=lambda k: _seg_dist(c, walls[k]["a"], walls[k]["b"]))
            if wi is None:
                continue
            w = walls[wi]
            d = w["b"] - w["a"]
            L = float(np.linalg.norm(d))
            along = float((c - w["a"]) @ d / max(L, 1e-9))
            bottom = M[1, 3] - hgt / 2 - floor_y
            sill = 0.0 if kind == "door" else max(0.0, bottom)
            openings.append({"type": kind, "wall": wi, "offset": max(0.0, along - wdt / 2),
                             "width": min(wdt, L), "height": hgt + (bottom if kind == "door" else 0.0),
                             "sill": sill, "source": "lidar"})

    # ---- furniture ----
    objects = []
    for o in scan.get("objects", []):
        M = _m(o["transform"])
        c = plan(M[:3, 3])
        u = axis(M)
        w, h, d = o["dimensions"]
        room = next((r["id"] for r in rooms if _inside(c, r["poly"])), None)
        objects.append({"label": o["category"], "room": room, "center": [c[0], c[1], h / 2],
                        "size": [w, d, h], "yaw": math.atan2(u[1], u[0])})

    # ---- origin at the bottom-left, 30 cm margin ----
    allxy = np.concatenate([r["poly"] for r in rooms] + [np.array([w["a"], w["b"]]) for w in walls]
                           or [np.zeros((1, 2))])
    origin = allxy.min(0) - 0.3
    height = round(float(np.median([w["height"] for w in walls])) if walls else 2.5, 3)

    def X(p):
        return [round(float(v), 3) for v in np.asarray(p, float)[:2] - origin]

    return {
        "version": 1,
        "rooms": [{"id": r["id"], "name": r["name"], "polygon": [X(p) for p in r["poly"]], "height": height}
                  for r in rooms],
        "walls": [{"id": f"w{i + 1}", "a": X(w["a"]), "b": X(w["b"]), "thickness": w["thickness"],
                   "height": round(w["height"], 3), "rooms": w["rooms"]} for i, w in enumerate(walls)],
        "openings": [{"id": f"o{i + 1}", "type": o["type"], "wall": f"w{o['wall'] + 1}",
                      "offset": round(o["offset"], 3), "width": round(o["width"], 3),
                      "height": round(o["height"], 3), "sill": round(o["sill"], 3), "source": o["source"]}
                     for i, o in enumerate(openings)],
        "objects": [{"id": f"f{i + 1}", "label": o["label"], "room": o["room"],
                     "center": X(o["center"]) + [round(o["center"][2], 3)],
                     "size": [round(v, 3) for v in o["size"]], "yaw": round(o["yaw"], 4)}
                    for i, o in enumerate(objects)],
        "scale": {"source": "lidar", "factor": 1.0},
    }


if __name__ == "__main__":
    import sys
    print(json.dumps(convert(json.loads(Path(sys.argv[1]).read_text())), indent=1))
