#!/usr/bin/env python3
"""Convert the Rocky statue STL into a compact, decimated mesh for the voice UI.

Output format (little-endian): b"RKY1", uint32 vertex_count, uint32 tri_count,
float32[vertex_count*3] positions (Y-up, centered, unit height), uint32[tri_count*3] indices.

Usage: python3 scripts/rocky-model/convert.py SRC.stl [--out voice/static/models/rocky.bin] [--target 60000]
"""
import argparse
import struct
import sys
from pathlib import Path

import numpy as np


def read_stl(path: Path) -> np.ndarray:
    data = path.read_bytes()
    n = struct.unpack_from("<I", data, 80)[0]
    if 84 + n * 50 != len(data):
        sys.exit("only binary STL is supported")
    rec = np.frombuffer(data, dtype=np.dtype([("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")]), count=n, offset=84)
    return rec["v"].astype(np.float64)


def cluster(tris: np.ndarray, cell: float):
    verts = tris.reshape(-1, 3)
    keys = np.floor((verts - verts.min(0)) / cell).astype(np.int64)
    _, inv = np.unique(keys, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    counts = np.bincount(inv)
    pos = np.stack([np.bincount(inv, weights=verts[:, i]) for i in range(3)], 1) / counts[:, None]
    idx = inv.reshape(-1, 3)
    idx = idx[(idx[:, 0] != idx[:, 1]) & (idx[:, 1] != idx[:, 2]) & (idx[:, 0] != idx[:, 2])]
    first = np.unique(np.sort(idx, 1), axis=0, return_index=True)[1]
    return pos, idx[np.sort(first)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src", type=Path)
    ap.add_argument("--out", type=Path, default=Path("voice/static/models/rocky.bin"))
    ap.add_argument("--target", type=int, default=60000)
    a = ap.parse_args()

    tris = read_stl(a.src)
    extent = np.ptp(tris.reshape(-1, 3), 0).max()
    lo, hi = extent / 2000, extent / 40
    for _ in range(18):  # binary search cell size for target tri count
        mid = (lo + hi) / 2
        pos, idx = cluster(tris, mid)
        if len(idx) > a.target:
            lo = mid
        else:
            hi = mid
    pos, idx = cluster(tris, hi)
    used, remap = np.unique(idx, return_inverse=True)
    pos, idx = pos[used], remap.reshape(-1, 3)

    # Z-up (mm) -> Y-up, feet at y=0, centered in x/z, unit height.
    pos = pos[:, [0, 2, 1]] * np.array([1, 1, -1])  # proper rotation, winding preserved
    pos -= [pos[:, 0].mean(), pos[:, 1].min(), pos[:, 2].mean()]
    pos /= pos[:, 1].max()

    a.out.parent.mkdir(parents=True, exist_ok=True)
    with a.out.open("wb") as f:
        f.write(b"RKY1" + struct.pack("<II", len(pos), len(idx)))
        f.write(pos.astype("<f4").tobytes())
        f.write(idx.astype("<u4").tobytes())
    print(f"{len(tris)} -> {len(idx)} tris, {len(pos)} verts, {a.out.stat().st_size/1e6:.2f} MB -> {a.out}")


if __name__ == "__main__":
    main()
