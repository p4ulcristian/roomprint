"""Run the whole pipeline on a local video without a space dir.

  python smoke.py <video> <out_dir> [wall_length_m]

The reconstruction is cached in <out_dir>/rec.npz (frames in <out_dir>/work), so a
second run only redoes the layout and the vision pass. Delete rec.npz to redo VGGT.
"""
import dataclasses
import gc
import json
import sys
import time
from pathlib import Path

import numpy as np

import frames as fr
import layout
import recon
import vision
from run import write_ply

video, out = Path(sys.argv[1]), Path(sys.argv[2])
wall = float(sys.argv[3]) if len(sys.argv) > 3 else None
out.mkdir(parents=True, exist_ok=True)
cache = out / "rec.npz"
if cache.exists():
    z = np.load(cache, allow_pickle=True)
    rec = recon.Recon(*(z[f.name] for f in dataclasses.fields(recon.Recon)))
    fl = [Path(p) for p in z["frames"]]
    print(f"cached reconstruction, {len(fl)} frames", flush=True)
else:
    import torch
    t = time.time()
    fl = fr.extract(video, out / "work")
    print(f"{len(fl)} frames in {time.time() - t:.0f}s", flush=True)
    model = recon.load_model()
    torch.cuda.reset_peak_memory_stats()
    t = time.time()
    rec = recon.reconstruct(fl, model, progress=lambda p: print(f"  recon {p:.0%}", flush=True))
    print(f"recon {time.time() - t:.0f}s, {len(rec.points)} points, peak VRAM "
          f"{torch.cuda.max_memory_allocated() / 2**30:.1f} GB", flush=True)
    del model
    gc.collect()
    torch.cuda.empty_cache()
    np.savez(cache, frames=np.array([str(p) for p in fl]), **dataclasses.asdict(rec))

space, pts, cols, view = layout.build(rec, wall_length_m=wall, progress=lambda p, s: print(f"  {s}", flush=True))
geo = len(space["openings"])
if vision.available():
    t = time.time()
    found = vision.detect(space, view, rec, fl, progress=lambda p, s: print(f"  {s}", flush=True))
    vision.unload()
    vision.apply(space, found)
    print(f"vision {time.time() - t:.0f}s: {len(found)} openings seen "
          f"({sum(o['sure'] for o in found)} sure); geometry had {geo}", flush=True)
(out / "space.json").write_text(json.dumps(space, indent=1))
write_ply(out / "preview.ply", pts, cols)
print(f"{len(space['rooms'])} rooms, {len(space['walls'])} walls, {len(space['openings'])} openings, "
      f"{len(space['objects'])} objects, scale {space['scale']}")
for r in space["rooms"]:
    print(f"  {r['name']}: {len(r['polygon'])} corners {r['polygon']}")
for o in space["openings"]:
    print(f"  {o['type']} on {o['wall']} at {o['offset']} w {o['width']} h {o['height']} sill {o['sill']} "
          f"[{o['source']}{'' if o.get('sure', True) else ', unsure'}]")
