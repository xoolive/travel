"""Distance of an aircraft to the WEDGE merge point (Haneda RWY 34L/34R
point merge, OSHIMA 1A arrival), with its course and the bearing to WEDGE,
every 20 s, from a jet1090 recording.

    python wedge.py JET1090.jsonl [OWN_ICAO24] [START_UTC END_UTC]

START_UTC/END_UTC as HH:MM:SS (default: the whole recording, positions
within 60 NM of WEDGE). The fixes come from AIP Japan RJTT AD2.24-STAR-11/12
(OSHIMA 1A, EFF 31 OCT 2024) and the RJTT waypoint table.
"""
import datetime
import json
import math
import sys

OWN = sys.argv[2] if len(sys.argv) > 2 else "39d2b1"
WINDOW = sys.argv[3:5] if len(sys.argv) > 4 else None


def dms(d, m, s):
    return d + m / 60 + s / 3600


# AIP Japan, RJTT waypoint coordinates.
WEDGE = (dms(35, 9, 0.4), dms(139, 58, 46.5))
FIXES = {
    "XAC": (dms(34, 42, 44.1), dms(139, 24, 50.5)),
    "ANZAC": (dms(34, 50, 28.8), dms(139, 41, 46.7)),
    "TT450": (dms(34, 52, 54.0), dms(139, 47, 6.0)),
    "TT451": (dms(34, 50, 16.8), dms(139, 57, 34.3)),
    "TT452": (dms(34, 51, 13.2), dms(140, 6, 0.1)),
    "TT453": (dms(34, 54, 38.5), dms(140, 13, 25.9)),
    "WANDA": (dms(35, 1, 55.3), dms(140, 19, 54.1)),
    "WEDGE": WEDGE,
    "ARLON": (dms(35, 15, 25.3), dms(139, 58, 59.8)),
}


def nm(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (*a, *b))
    c = math.sin(la1) * math.sin(la2) + math.cos(la1) * math.cos(la2) * math.cos(lo2 - lo1)
    return 3440.065 * math.acos(max(-1, min(1, c)))


def bearing(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (*a, *b))
    y = math.sin(lo2 - lo1) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(lo2 - lo1)
    return math.degrees(math.atan2(y, x)) % 360


def hms(t):
    return datetime.datetime.fromtimestamp(t, datetime.UTC).strftime("%H:%M:%S")


print("fix     NM to WEDGE")
for name, p in FIXES.items():
    print(f"{name:7s} {nm(p, WEDGE):6.2f}")
print()
print("UTC        NM to WEDGE  altitude  course  bearing to WEDGE  nearest fix")

last, prev = 0.0, None
for line in open(sys.argv[1]):
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get("icao24") != OWN or d.get("latitude") is None:
        continue
    t = d["timestamp"]
    if t - last < 20:
        continue
    p = (d["latitude"], d["longitude"])
    if WINDOW:
        if not WINDOW[0] <= hms(t) <= WINDOW[1]:
            continue
    elif nm(p, WEDGE) > 60:
        continue
    last = t
    course = bearing(prev, p) if prev else float("nan")
    prev = p
    fix, dist = min(((k, nm(p, v)) for k, v in FIXES.items()), key=lambda kv: kv[1])
    print(
        f"{hms(t)}  {nm(p, WEDGE):8.1f}  {d.get('altitude')!s:>8}  {course:6.0f}  "
        f"{bearing(p, WEDGE):12.0f}      {fix} {dist:.1f} NM"
    )
