# Roomprint

Share a link, people film their rooms, we turn the video into a dimensioned
floor plan (3D view + blueprint) and later printable diorama panels.

See `PLAN.md` and `SPACE_FORMAT.md`.

## Run

```sh
# web (upload page, viewer)
DATA_DIR=./data PORT=4490 bun web/server.ts
bun web/admin.ts invite "Grandma's flat"     # prints the upload + viewer links
bun web/admin.ts list

# worker (GPU)
cd worker
uv venv --python 3.12 .venv
# constraints-cache.txt pins torch + CUDA libs to what other venvs on the machine
# already use, so uv installs them from its cache instead of downloading ~3 GB
uv pip install --python .venv -c constraints-cache.txt torch torchvision
uv pip install --python .venv -c constraints-cache.txt -r requirements.txt
uv pip install --python .venv --no-deps git+https://github.com/facebookresearch/vggt
.venv/bin/python run.py watch                # or: run.py process <space_id>
```

The systemd units in `deploy/` read `~/.config/roomprint/env` (`DATA_DIR`, `BASE_URL`,
`TUNNEL_HOST`, `APP_SECRET`, and `BRUSH` for splats, below).

The web server also needs `rsvg-convert` (floor plan as PDF and PNG) and the worker
`ffmpeg`/`ffprobe` (frames of the walk video) on the PATH.

The worker only starts a job when `NEED_VRAM_MB` (default 10000) is free.
Doors and windows are read from the frames by a local vision model through Ollama
(`ROOMPRINT_VLM`, default `gemma4:e4b`), after VGGT has left the GPU; without it the
worker falls back to guessing openings from holes in the point cloud.

## What a LiDAR scan becomes

A scan from the app uploads four things: the scan itself (`.roomplan`, or `.freescan` for
a scan without rooms), the walk video (`.mov`), the LiDAR depth with small photos
(`.rgbd`) and the camera's pose for every video frame (`.poses`). The worker turns them
into, in this order, each on its own so the floor plan never waits for the rest:

1. `space.json`: the floor plan (`roomplan.py`). A free scan gets one without rooms.
2. `mesh.ply`: the real rooms as a mesh with vertex colours, fused from the depth (`fuse.py`).
3. `textured.glb`: the same mesh, thinned, unwrapped and painted from the video's
   full-resolution frames (`texture.py`, `views.py`); from the depth file's small photos
   when a scan has no pose track. Uses the GPU if 3 GB are free, the CPU otherwise.
4. `splat.ply` + `splat.splat`: a Gaussian splat (`splat.py`), only when asked for
   (`POST /api/s/<token>/splat`, the viewer's Export sheet), because it holds the GPU for
   minutes. It is trained by [Brush](https://github.com/ArthurBrussee/brush), a prebuilt
   trainer that runs through Vulkan; set `BRUSH` to its `brush_app` binary. The worker
   waits for `SPLAT_VRAM_MB` (default 3000) of free VRAM; training peaks near 1.5 GB.

## Exports

`GET /api/s/<token>/export/<kind>.<format>`, built on first request and cached in the
space's `exports/` folder until their source changes (`web/exports.ts`, `worker/export.py`):

| kind | formats | what |
|---|---|---|
| `mesh` | glb, obj (zipped with its texture), usdz, stl, ply | the real scan |
| `points` | ply, las, xyz | coloured points sampled from it |
| `plan` | svg, pdf (1:50), png, dxf | the floor plan |
| `model` | glb, obj, usdz, stl | the drawn model: walls, floors, furniture boxes |
| `splat` | ply | the Gaussian splat |
| `raw` | zip | photos, depth and poses in nerfstudio layout |

`?crop=x0,y0,z0,x1,y1,z1` (plan coordinates, metres) crops `mesh` and `points`; the
viewer's Crop tool sets it. The viewer also measures between any two tapped points.

## iOS app (`ios/`)

LiDAR room scans with Apple's RoomPlan, uploaded to an invite as a `.roomplan` file
that `worker/roomplan.py` turns into `space.json` without the GPU. A second mode, Free
scan, records the same video, depth and poses without RoomPlan, for things that are not
rooms. While scanning, both modes show the scan so far (`LiveScan.swift`): ARKit's
live mesh coloured from the depth frames (points from the depth alone where the session
gives no mesh), as a map from above in a corner and full screen to turn around before
uploading, with the edges of holes marked. The free scan also tints scanned surfaces in
the camera view (orange where they were seen too little). A line of advice shows when
moving too fast, too far away or in the dark. The space's page in the app is the
web viewer in a web view; exports and files tapped there are downloaded by the app and
handed to the share sheet (a USDZ opens in AR Quick Look). The interface uses Liquid
Glass on iOS 26 and the blur material on iOS 17 and 18. Uploads run in an
iOS background session (`Uploader.swift`), one task per 8 MB chunk, so they finish
with the app closed; the server takes chunks in any order and starts on the scan as
soon as its `.roomplan` file is complete. Built from Linux
with [xtool](https://github.com/xtool-org/xtool): `cd ios && xtool dev` with the
phone on USB and unlocked. It needs `ios/Sources/Roomprint/Secrets.swift` (not in
git):

```swift
enum Secrets {
    static let baseURL = "https://roomprint.example.com"
    static let appSecret = "<APP_SECRET from the server's env>"
}
```

 Free Apple
provisioning: reinstall every 7 days. Invites open in it via `roomprint://u/<token>`
(the upload page links to that) or by pasting the link.

`python smoke.py <video> <out_dir>` runs everything on a local file and caches the
reconstruction, so layout and vision changes can be retried without VGGT.
