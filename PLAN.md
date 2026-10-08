# Roomprint — plan

Share a link → people upload a video of their room → we turn it into a dimensioned
room model → printable diorama panels.

## Flow

1. **Upload page** (any phone browser): filming tips, video upload, one scale
   measurement ("longest wall length"), optional room name. Multiple rooms per space.
   Also accepts LiDAR exports (Polycam / 3D Scanner App USDZ/OBJ).
2. **Server**: stores uploads, queues jobs, shows status.
3. **GPU worker**: video → frames → 3D reconstruction (VGGT / MASt3R, COLMAP fallback)
   → point cloud → scale from the measurement → layout (SpatialLM: walls, doors,
   windows, furniture boxes) → `room.json` + GLB.
4. **Viewer**: three.js preview of the room; fix a wall length or a door by hand
   before printing.
5. **Print export**: Blender script → walls at chosen scale (1:24 / 1:12), cut into
   panels that fit the X1C bed (256 mm), tabs/slots, door and window openings → STLs.

## Pieces

- `web/`     upload page + viewer + API
- `worker/`  Python GPU pipeline
- `print/`   Blender panel export

## Decisions

- Access: per-person invite links (no account; token in the URL).
- Hosting: behind a reverse proxy; uploads stored on the GPU machine.
- GPU: a 16 GB card (RTX 5060 Ti). Jobs queue and run when enough VRAM is free
  (daemons hold ~12 GB); steps run sequentially (VGGT ~8-12 GB, then SpatialLM).
  Move the worker to a bigger GPU only if 16 GB proves too tight.

- Web stack: bun server (upload, invites, jobs, viewer); Python worker separate.
- Multiple rooms per space. Best capture: one continuous walk through all rooms
  (rooms come out aligned). Separate clips per room also accepted; those get
  arranged afterwards (doorway matching or by hand on the blueprint).
- Two views of one `space.json`: **3D** (orbit, walls/doors/windows/furniture,
  click a room) and **Blueprint** (top-down plan with wall lengths, openings,
  room names). Edits in either update both.
