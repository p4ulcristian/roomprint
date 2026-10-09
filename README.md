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
`TUNNEL_HOST`, `APP_SECRET`).

The worker only starts a job when `NEED_VRAM_MB` (default 10000) is free.
Doors and windows are read from the frames by a local vision model through Ollama
(`ROOMPRINT_VLM`, default `gemma4:e4b`), after VGGT has left the GPU; without it the
worker falls back to guessing openings from holes in the point cloud.

## iOS app (`ios/`)

LiDAR room scans with Apple's RoomPlan, uploaded to an invite as a `.roomplan` file
that `worker/roomplan.py` turns into `space.json` without the GPU. Uploads run in an
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
