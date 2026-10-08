# space.json

One file per space (an apartment, a house floor). Produced by the worker,
edited in the viewer, consumed by the 3D view, the blueprint and the print export.

Units are metres. Floor plane is x/y, z is up. Floor is at z = 0.

```json
{
  "version": 1,
  "id": "sp_ab12cd",
  "name": "Grandma's flat",
  "rooms": [
    {
      "id": "r1",
      "name": "Kitchen",
      "polygon": [[0, 0], [3.2, 0], [3.2, 2.8], [0, 2.8]],
      "height": 2.6
    }
  ],
  "walls": [
    {
      "id": "w1",
      "a": [0, 0],
      "b": [3.2, 0],
      "thickness": 0.12,
      "height": 2.6,
      "rooms": ["r1"]
    }
  ],
  "openings": [
    {
      "id": "o1",
      "type": "door",
      "wall": "w1",
      "offset": 0.4,
      "width": 0.9,
      "height": 2.05,
      "sill": 0
    },
    {
      "id": "o2",
      "type": "window",
      "wall": "w1",
      "offset": 1.8,
      "width": 1.2,
      "height": 1.3,
      "sill": 0.9
    }
  ],
  "objects": [
    {
      "id": "f1",
      "label": "table",
      "room": "r1",
      "center": [1.5, 1.4, 0.375],
      "size": [1.2, 0.8, 0.75],
      "yaw": 0
    }
  ],
  "scale": { "source": "measurement", "factor": 1.0 }
}
```

- `walls[].a/b` are centre-line endpoints. A wall shared by two rooms lists both.
- `openings[].offset` is the distance along the wall from `a` to the opening's near edge.
- `objects[].center` is the box centre; `size` is [width (x), depth (y), height (z)]
  before rotation; `yaw` is radians around z.
- `openings[].source`: `doorway` (floor runs on between two rooms), `gap` (hole in the
  point cloud; only when the vision model was not available), `vision` (the vision model
  saw it in the frames). `openings[].sure` is false when only one frame showed it; the
  blueprint draws those in amber.
- `scale.source`: `measurement` (user typed a wall length), `marker` (A4 sheet),
  `lidar` (metric export), `guess`.
