"""Dead reckoning of our own aircraft through GNSS outages, from Comm-B
(BDS 5,0 TAS, BDS 6,0 magnetic heading and Mach) and the wind measured
before the outage."""

import functools
import json
import math
import sys
from bisect import bisect_left
from datetime import UTC, datetime

import numpy as np
from openap import aero
from pygeomag import GeoMag

ICAO = "39d2b1"
R = 6371008.8
KT = 1852 / 3600
geomag = GeoMag()


def hms(t):
    return datetime.fromtimestamp(t, UTC).strftime("%H:%M:%S")


def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            if ICAO in line:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass  # line being written
    return sorted(rows, key=lambda r: r["timestamp"])


def series(rows):
    """Trusted positions, ADS-B velocities, air data."""
    fixes, ground, air, alt = [], [], [], []
    nacp = 0
    for r in rows:
        t = r["timestamp"]
        if r.get("bds") in ("62", "65") and r.get("NACp") is not None:
            nacp = r["NACp"]
        if r["df"] == "17" and r.get("bds") == "05" and r.get("tc") == 11 and "latitude" in r and nacp >= 8:
            fixes.append((t, r["latitude"], r["longitude"]))
        if r["df"] == "17" and r.get("bds") == "09" and r.get("groundspeed") and r.get("track") is not None:
            ground.append((t, r["groundspeed"], r["track"]))
        if r.get("altitude") and r["df"] in ("0", "4", "20"):
            alt.append((t, r["altitude"]))
        b50, b60 = r.get("bds50"), r.get("bds60")
        if b60 and "bds50" not in r and b60.get("heading") is not None:
            air.append((t, "hdg", b60["heading"], b60.get("Mach")))
        if b50 and "bds60" not in r and b50.get("TAS"):
            air.append((t, "tas", b50["TAS"], None))
    return fixes, ground, air, alt


@functools.lru_cache(maxsize=100_000)
def _declination(lat, lon):
    return geomag.calculate(glat=lat, glon=lon, alt=11, time=2026.87).d


class Air:
    """Air vector (true heading, TAS) at any time, from the latest messages."""

    def __init__(self, air, alt):
        self.hdg = [(t, h, m) for t, k, h, m in air if k == "hdg"]
        self.tas = [(t, v) for t, k, v, _ in air if k == "tas"]
        self.alt = alt
        self.th = [x[0] for x in self.hdg]
        self.tt = [x[0] for x in self.tas]
        self.ta = [x[0] for x in alt]

    @staticmethod
    def latest(times, values, t):
        i = bisect_left(times, t)
        return values[max(i - 1, 0)] if values else None

    def at(self, t, lat, lon):
        h = self.latest(self.th, self.hdg, t)
        a = self.latest(self.ta, self.alt, t)
        v = self.latest(self.tt, self.tas, t)
        declination = _declination(round(lat, 1), round(lon, 1))
        heading = (h[1] + declination) % 360
        if v and abs(v[0] - t) < 10:
            tas = v[1]
        else:  # Mach and pressure altitude, ISA (openap)
            tas = aero.mach2tas(h[2], a[1] * aero.ft) / aero.kts
        return heading, tas


def vec(speed, course):
    c = math.radians(course)
    return np.array([speed * math.sin(c), speed * math.cos(c)])  # east, north


def move(lat, lon, east, north):
    lat2 = lat + math.degrees(north / R)
    lon2 = lon + math.degrees(east / (R * math.cos(math.radians(lat))))
    return lat2, lon2


def distance(a, b):
    (la1, lo1), (la2, lo2) = a, b
    p1, p2 = math.radians(la1), math.radians(la2)
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lo2 - lo1) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def wind(ground, air, fixes, t0, window=600):
    """Mean wind (east, north, kt) over the window before t0: ground vector
    from ADS-B minus air vector."""
    samples = []
    tf = [f[0] for f in fixes]
    for t, gs, trk in ground:
        if t0 - window <= t <= t0:
            f = fixes[max(bisect_left(tf, t) - 1, 0)]
            hdg, tas = air.at(t, f[1], f[2])
            samples.append(vec(gs, trk) - vec(tas, hdg))
    s = np.array(samples)
    return s.mean(axis=0), s.std(axis=0), len(s)


def propagate(start, w, air, t1, step=1.0):
    t, lat, lon = start
    path = [(t, lat, lon)]
    while t < t1:
        dt = min(step, t1 - t)
        hdg, tas = air.at(t, lat, lon)
        v = (vec(tas, hdg) + w) * KT
        lat, lon = move(lat, lon, v[0] * dt, v[1] * dt)
        t += dt
        path.append((t, lat, lon))
    return path


def fix_at(fixes, t):
    tf = [f[0] for f in fixes]
    i = bisect_left(tf, t)
    return fixes[min(i, len(fixes) - 1)]


def run(path):
    rows = load(path)
    fixes, ground, air_, alt = series(rows)
    air = Air(air_, alt)
    now = rows[-1]["timestamp"]

    # Outages: gaps over 30 s between trusted fixes (once airborne at cruise).
    gaps = [(a, b) for a, b in zip(fixes, fixes[1:]) if b[0] - a[0] > 30 and a[0] > fixes[0][0] + 1800]
    print(f"{len(fixes)} trusted fixes, {hms(fixes[0][0])}–{hms(fixes[-1][0])}; data until {hms(now)}")

    print("\n# Validation: dead reckoning through simulated outages (wind of the 10 min before)")
    for start in [1794753600 + 60 * m for m in (0, 20, 40, 60, 80)]:  # 14:00, 14:20, …
        f0 = fix_at(fixes, start)
        w, sd, n = wind(ground, air, fixes, f0[0])
        for minutes in (5, 10, 20):
            t1 = f0[0] + 60 * minutes
            truth = fix_at(fixes, t1)
            if abs(truth[0] - t1) > 5:
                continue
            p = propagate(f0, w, air, truth[0])[-1]
            err = distance(p[1:], truth[1:]) / 1852
            print(f"  from {hms(f0[0])}, wind {np.hypot(*w):3.0f} kt from {math.degrees(math.atan2(-w[0], -w[1])) % 360:3.0f}°, {minutes:2d} min: {err:4.1f} NM")

    for a, b in gaps:
        w, sd, n = wind(ground, air, fixes, a[0])
        print(f"\n# Outage {hms(a[0])} → {hms(b[0]) if b else '…'} ({(b[0] - a[0]) / 60:.1f} min)")
        print(f"  wind {np.hypot(*w):.0f} kt from {math.degrees(math.atan2(-w[0], -w[1])) % 360:.0f}° (sd {sd[0]:.0f}/{sd[1]:.0f} kt, {n} samples)")
        p = propagate(a, w, air, b[0])[-1]
        print(f"  reconstructed at recovery: {distance(p[1:], b[1:]) / 1852:.2f} NM from the first fix after")

    last = fixes[-1]
    if now - last[0] > 30:
        w, sd, n = wind(ground, air, fixes, last[0])
        path_ = propagate(last, w, air, now)
        p = path_[-1]
        hdg, tas = air.at(now, p[1], p[2])
        gv = vec(tas, hdg) + w
        print(f"\n# Current outage since {hms(last[0])} ({(now - last[0]) / 60:.1f} min)")
        print(f"  last fix {last[1]:.4f} {last[2]:.4f}")
        print(f"  now {hms(now)}: {p[1]:.4f} {p[2]:.4f}, true heading {hdg:.1f}°, TAS {tas:.0f} kt, "
              f"track {math.degrees(math.atan2(gv[0], gv[1])) % 360:.1f}°, GS {np.hypot(*gv):.0f} kt")
        json.dump([{"t": t, "lat": la, "lon": lo} for t, la, lo in path_[::10]],
                  open("current.json", "w"))
        return p, math.degrees(math.atan2(gv[0], gv[1])) % 360
    return None, None


if __name__ == "__main__":
    run(sys.argv[1] if len(sys.argv) > 1 else "own.jsonl")
