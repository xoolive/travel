"""Live: history from the jet1090 recording, then Redis. Dead reckoning from
the last trusted fix. Each completed turn near a filed waypoint (fly-by,
taken at mid-turn) resets the position to the waypoint and corrects the wind
by the error accumulated since the previous anchor."""

import json
import pathlib
import math
import sys
import time

import numpy as np
import redis

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import reconstruct as rc  # noqa: E402
from plan import bearing, dist, waypoints, xtrack  # noqa: E402

DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 420
rows = rc.load(sys.argv[2] if len(sys.argv) > 2 else "own.jsonl")
wps = waypoints()
sub = redis.Redis.from_url("redis://127.0.0.1:6379").pubsub()
sub.subscribe("jet1090")


def heading_at(hdg, t):
    i = np.searchsorted(hdg[:, 0], t)
    return hdg[max(i - 1, 0), 1]


def turns(air, t0, now):
    """Completed turns after t0: (mid-turn time, change in degrees)."""
    hdg = np.array([(t, h) for t, h, _ in air.hdg if t >= t0 - 60])
    if len(hdg) < 10:
        return []
    grid = np.arange(t0 + 15, now - 15, 5.0)
    h = np.unwrap(np.radians([heading_at(hdg, t) for t in np.arange(t0, now, 5.0)]))
    h = np.degrees(h)
    rate = (h[6:] - h[:-6]) / 30  # °/s over 30 s, centred
    grid = np.arange(t0, now, 5.0)[3:-3]
    out, i = [], 0
    while i < len(rate):
        if abs(rate[i]) > 0.1:
            j = i
            while j < len(rate) and abs(rate[j]) > 0.05:
                j += 1
            a, b = grid[i] - 20, grid[min(j, len(grid) - 1)] + 20
            if b + 10 < now:  # finished and settled
                before, after = heading_at(hdg, a), heading_at(hdg, b)
                change = ((after - before + 540) % 360) - 180
                if abs(change) > 5:
                    half = before + change / 2
                    seg = hdg[(hdg[:, 0] >= a) & (hdg[:, 0] <= b)]
                    mid = next((t for t, x in seg if (x - half) * np.sign(change) >= 0), (a + b) / 2)
                    out.append((mid, change))
            i = j
        i += 1
    return out


CHANNEL = "datalink-estimated"  # matched by Travel's datalink-* pattern; not jet1090
MAX_OFFSET = 10  # NM: farther from every leg, the estimate is left as it is


def on_leg(lat, lon):
    """The estimate moved onto the nearest filed leg (keeping its progress
    along it): the aircraft flies its legs within a few NM, so the lateral
    error of dead reckoning is dropped. Returns (lat, lon, leg name, offset)."""
    best = None
    for (na, a), (nb, b) in zip(wps, wps[1:]):
        xt, f = xtrack((lat, lon), a, b)
        if -0.02 <= f <= 1.02 and abs(xt) < MAX_OFFSET and (best is None or abs(xt) < abs(best[0])):
            best = (xt, f, na, nb, a, b)
    if best is None:
        return lat, lon, None, None
    xt, f, na, nb, a, b = best
    q = destination(a, bearing(a, b), f * dist(a, b))
    return q[0], q[1], f"{na}→{nb}", xt


def destination(p, course, distance):
    la, lo = map(math.radians, p)
    c, d = math.radians(course), distance / rc.R
    la2 = math.asin(math.sin(la) * math.cos(d) + math.cos(la) * math.sin(d) * math.cos(c))
    lo2 = lo + math.atan2(math.sin(c) * math.sin(d) * math.cos(la), math.cos(d) - math.sin(la) * math.sin(la2))
    return math.degrees(la2), math.degrees(lo2)


def message(now, lat, lon, alt, track, gs):
    return json.dumps({
        "timestamp": now, "icao24": "39d2b1", "latitude": round(lat, 5), "longitude": round(lon, 5),
        "altitude": alt, "track": round(track, 1), "groundspeed": round(gs), "estimated": "dead-reckoning",
    })
publisher = redis.Redis.from_url("redis://127.0.0.1:6379")
state = None  # (t, lat, lon), wind, altitude, last fix time: from the last full update
last_publish = 0


def publish(now):
    """Propagates the state to now and publishes it, while GNSS is out."""
    global state
    (t, la, lo), w, alt, fixed = state
    if now - fixed < 20:  # trusted positions again: real data speaks
        return
    fixes_air = rc.Air(air_rows, alt_rows)
    p = rc.propagate((t, la, lo), w, fixes_air, now)[-1]
    state = (p, w, alt, fixed)
    hdg, tas = fixes_air.at(now, p[1], p[2])
    gv = rc.vec(tas, hdg) + w
    lat, lon, _, _ = on_leg(p[1], p[2])
    publisher.publish(CHANNEL, message(now, lat, lon, alt, math.degrees(math.atan2(gv[0], gv[1])) % 360, np.hypot(*gv)))


start, last_report, seen = time.time(), 0, set()
air_rows, alt_rows = [], []
while time.time() - start < DURATION:
    m = sub.get_message(timeout=1.0)
    if m and m["type"] == "message" and b"39d2b1" in m["data"]:
        try:
            rows.append(json.loads(m["data"]))
        except json.JSONDecodeError:
            pass
    if state and time.time() - last_publish >= 2:
        last_publish = time.time()
        publish(max(x["timestamp"] for x in rows[-50:]))
    if time.time() - last_report < 10:
        continue
    last_report = time.time()
    fixes, ground, air_, alt = rc.series(rows)
    air = rc.Air(air_, alt)
    now = max(x["timestamp"] for x in rows[-200:])
    last = fixes[-1]
    w, _, _ = rc.wind(ground, air, fixes, last[0])
    anchor = last
    # Replay the turns since the last fix: reset at each waypoint, correct the wind.
    for mid, change in turns(air, last[0], now):
        p = rc.propagate(anchor, w, air, mid)[-1]
        name, q = min(wps, key=lambda x: dist(p[1:], x[1]))
        d = dist(p[1:], q) / 1852
        if d > 12:
            continue
        de = (q[1] - p[2]) * math.cos(math.radians(q[0])) * math.pi / 180 * rc.R
        dn = (q[0] - p[1]) * math.pi / 180 * rc.R
        correction = np.array([de, dn]) / (mid - anchor[0]) / rc.KT
        if (name, round(mid)) not in seen:
            seen.add((name, round(mid)))
            print(f"  TURN {change:+.1f}° at {rc.hms(mid)} (mid-turn): {name}, DR was {d:.1f} NM off; "
                  f"wind correction {np.hypot(*correction):.0f} kt from {math.degrees(math.atan2(-correction[0], -correction[1])) % 360:.0f}°",
                  flush=True)
        w = w + correction
        anchor = (mid, q[0], q[1])
    p = rc.propagate(anchor, w, air, now)[-1]
    air_rows, alt_rows = air_, alt
    # Dead reckoning goes on unconstrained; what is shown is put on the leg.
    state = (p, w, alt[-1][1], last[0])
    hdg, tas = air.at(now, p[1], p[2])
    gv = rc.vec(tas, hdg) + w
    track = math.degrees(math.atan2(gv[0], gv[1])) % 360
    lat, lon, leg, offset = on_leg(p[1], p[2])
    if now - last[0] >= 20:
        publisher.publish(CHANNEL, message(now, lat, lon, alt[-1][1], track, np.hypot(*gv)))
    pos = (lat, lon)
    ahead = [(n, q) for n, q in wps if abs(((bearing(pos, q) - track + 540) % 360) - 180) < 30 and dist(pos, q) < 900e3]
    nxt = min(ahead, key=lambda x: dist(pos, x[1])) if ahead else None
    line = (f"{rc.hms(now)} est {lat:.3f} {lon:.3f} "
            + (f"on {leg} (DR {offset:+.1f} NM off) " if leg else "off the legs ")
            + f"(from {rc.hms(anchor[0])}) mag hdg {air.hdg[-1][1]:.1f} "
            f"track {track:.1f} GS {np.hypot(*gv):.0f} kt wind {np.hypot(*w):.0f} kt/{math.degrees(math.atan2(-w[0], -w[1])) % 360:.0f}° "
            f"fix age {(now - last[0]) / 60:.1f} min")
    if nxt:
        d = dist(pos, nxt[1]) / 1852
        line += f" | {nxt[0]} {d:.1f} NM, bearing {bearing(pos, nxt[1]):.1f}°, ETA {rc.hms(now + d / np.hypot(*gv) * 3600)}"
    print(line, flush=True)
