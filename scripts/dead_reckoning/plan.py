"""Compare the flown (and reconstructed) track with the filed route."""

import json
import pathlib
import math
import sys
from datetime import UTC, datetime

R = 6371008.8
# AF162 as resolved by Travel (`Travel --plan ~/20261115_AA89675273_LFPG_RJTT.flight.json`).
NAMES = (pathlib.Path(__file__).resolve().parent / "route.txt").read_text().split()


def hms(t):
    return datetime.fromtimestamp(t, UTC).strftime("%H:%M:%S")


def rad(p):
    return math.radians(p[0]), math.radians(p[1])


def dist(a, b):
    (p1, l1), (p2, l2) = rad(a), rad(b)
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin((l2 - l1) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def bearing(a, b):
    (p1, l1), (p2, l2) = rad(a), rad(b)
    y = math.sin(l2 - l1) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(l2 - l1)
    return math.degrees(math.atan2(y, x)) % 360


def xtrack(p, a, b):
    """Cross-track (NM, right positive) and along-track fraction of p on a→b."""
    d13 = dist(a, p) / R
    t13, t12 = math.radians(bearing(a, p)), math.radians(bearing(a, b))
    xt = math.asin(math.sin(d13) * math.sin(t13 - t12))
    at = math.acos(max(-1, min(1, math.cos(d13) / math.cos(xt))))
    return xt * R / 1852, at * R / dist(a, b) * (1 if math.cos(t13 - t12) > 0 else -1)


def waypoints():
    """The route points: route.tsv (NAME LAT LON [x-plane], from
    `Travel --plan FILE`, with X-Plane airways where AIXM has none) when
    present, else the names of route.txt against the AIRAC cache."""
    tsv = pathlib.Path(__file__).resolve().parent / "route.tsv"
    if tsv.exists():
        rows = [l.split("\t") for l in tsv.read_text().splitlines() if l.count("\t") >= 2]
        return [(r[0], (float(r[1]), float(r[2]))) for r in rows]
    index = json.load(open(f"{__import__('os').path.expanduser('~')}/Library/Caches/travel/AIRAC_2606.json"))
    by = {}
    for pid, p in index["points"].items():
        by.setdefault(p["name"], []).append((p["latitude"], p["longitude"]))
    out = []
    for n in NAMES:
        cands = by.get(n, [])
        if not cands:
            continue
        ref = out[-1][1] if out else (49.0, 2.55)
        out.append((n, min(cands, key=lambda c: dist(c, ref))))
    return out


def leg_of(p, wps):
    best = None
    for (na, a), (nb, b) in zip(wps, wps[1:]):
        xt, f = xtrack(p, a, b)
        if -0.05 <= f <= 1.05 and (best is None or abs(xt) < abs(best[2])):
            best = (na, nb, xt, f)
    return best


def main():
    wps = waypoints()
    i = NAMES.index("UDROS")
    print("Route from UDROS:", "  ".join(f"{n} {la:.2f}/{lo:.2f}" for n, (la, lo) in wps[i:i + 10]))

    rows = [json.loads(l) for l in open("own.jsonl") if '"latitude"' in l]
    fixes = [(r["timestamp"], (r["latitude"], r["longitude"])) for r in rows if r.get("tc") == 11]
    print("\nGNSS track against the filed legs (every 5 min):")
    last = 0
    for t, p in fixes:
        if t - last >= 300 and t > 1794756000:
            leg = leg_of(p, wps)
            print(f"  {hms(t)} {p[0]:.3f} {p[1]:.3f}  " + (f"{leg[0]}→{leg[1]} {leg[3]:4.0%} xt {leg[2]:+5.1f} NM" if leg else "off route"))
            last = t
    path = json.load(open("current.json"))
    print("\nReconstructed track (outage):")
    for q in path[::30] + [path[-1]]:
        p = (q["lat"], q["lon"])
        leg = leg_of(p, wps)
        print(f"  {hms(q['t'])} {p[0]:.3f} {p[1]:.3f}  " + (f"{leg[0]}→{leg[1]} {leg[3]:4.0%} xt {leg[2]:+5.1f} NM" if leg else "off route"))

    p = (path[-1]["lat"], path[-1]["lon"])
    track = float(sys.argv[1]) if len(sys.argv) > 1 else None
    print("\nAhead: bearing from the reconstructed position, leg course, distance")
    for (na, a), (nb, b) in zip(wps, wps[1:]):
        if dist(p, b) < 700e3 and xtrack(p, a, b)[1] < 1:
            print(f"  {nb:6s} bearing {bearing(p, b):5.1f}°  leg {na}→{nb} course {bearing(a, b):5.1f}°  {dist(p, b) / 1852:5.0f} NM"
                  + (f"  Δ track {((bearing(p, b) - track + 540) % 360) - 180:+5.1f}°" if track else ""))


if __name__ == "__main__":
    main()
