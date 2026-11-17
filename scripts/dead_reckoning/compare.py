"""Flighty's track for our flight against GNSS fixes and dead reckoning."""

import math
import pathlib
import sys
from bisect import bisect_left

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import numpy as np  # noqa: E402

import reconstruct as rc  # noqa: E402
from flighty_pb import parse, varint  # noqa: E402
from plan import bearing, dist, waypoints  # noqa: E402

FLIGHT = "c5a9b1ff-dafd-4bf3-9a94-57c054b79dda"


def flighty(path):
    b = open(path, "rb").read()
    i = 0
    while i < len(b):
        k, i = varint(b, i)
        n, i = varint(b, i)
        if k >> 3 == 2 and FLIGHT.encode() in b[i:i + n][:60]:
            pts = []
            for f, v in parse(b[i:i + n]):
                if f == 2:
                    for kk, p in v:
                        if kk == 1:
                            d = {a: c for a, c in p if not isinstance(c, list)}
                            ll = dict(next(c for a, c in p if a == 1))
                            pts.append((d[5], ll[1], ll[2], d.get(2), d.get(3), d.get(4), d.get(6)))
            return sorted(pts)
        i += n


def along_cross(p, truth, course):
    """Offset of p from truth: along course (ahead +) and across (right +), NM."""
    d = dist(truth, p) / 1852
    b = math.radians(bearing(truth, p) - course)
    return d * math.cos(b), d * math.sin(b)


rows = rc.load("own.jsonl")
fixes, ground, air_, alt = rc.series(rows)
air = rc.Air(air_, alt)
tf = [f[0] for f in fixes]
now = rows[-1]["timestamp"]
last = fixes[-1]
w, _, _ = rc.wind(ground, air, fixes, last[0])

# Mid-turn at UDROS: magnetic heading halfway between before and after.
h = [(t, x) for t, x, _ in air.hdg if 1794759540 <= t <= 1794759720]  # 16:19–16:22
before, after = np.mean([x for t, x in h[:20]]), np.mean([x for t, x in h[-20:]])
mid = next(t for t, x in h if x < (before + after) / 2)
udros = dict(waypoints())["UDROS"]
print(f"turn at UDROS: {before:.1f}° → {after:.1f}° magnetic, mid-turn {rc.hms(mid)}")

dr1 = rc.propagate(last, w, air, mid)
print(f"DR at mid-turn vs UDROS: along {along_cross(dr1[-1][1:], udros, 118)[0]:+.1f} NM, "
      f"across {along_cross(dr1[-1][1:], udros, 118)[1]:+.1f} NM")
dr2 = rc.propagate((mid, *udros), w, air, now)
dr = dr1 + dr2
td = [x[0] for x in dr]


def ours(t):
    """Best estimate of our position at t: GNSS fix within 3 s, else DR."""
    i = bisect_left(tf, t)
    for j in (i - 1, i):
        if 0 <= j < len(fixes) and abs(fixes[j][0] - t) < 3 and t <= last[0]:
            return fixes[j][1:], "gnss"
    if t > last[0]:
        return dr[min(bisect_left(td, t), len(dr) - 1)][1:], "dr"
    return None, None


pts = flighty(sys.argv[1])
print(f"Flighty: {len(pts)} points {rc.hms(pts[0][0])}–{rc.hms(pts[-1][0])}")
print("time      flighty lat/lon      alt   trk  gs  flag  ours  along  across (NM, Flighty minus ours)")
for t, la, lo, a, trk, gs, flag in pts:
    if t < 1794756600:  # from 15:30
        continue
    p, src = ours(t)
    if p is None:
        continue
    course = trk or 110
    al, ac = along_cross((la, lo), p, course)
    print(f"{rc.hms(t)} {la:8.4f} {lo:8.4f} {a or 0:6d} {trk or 0:4d} {gs or 0:4d} {flag or 0:3d}  {src:4s} {al:+6.1f} {ac:+6.1f}")
