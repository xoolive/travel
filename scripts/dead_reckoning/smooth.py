"""Post-flight reconstruction through a GNSS outage: extended Kalman filter
forward, Rauch–Tung–Striebel smoother backward.

State: latitude, longitude, wind (east, north) and a heading bias. The air
vector (BDS 6,0 magnetic heading + declination, BDS 5,0 TAS or Mach) drives
the position; GNSS positions (NACp >= 8) and ADS-B ground velocities, before
and after the outage, are the measurements. Optionally, mid-turn times at
filed waypoints are position measurements too (--waypoints).

The forward pass alone is dead reckoning with a wind estimated before the
outage. The backward pass brings the fixes after the outage back in time:
the wind and bias that best join both ends.

    python smooth.py own.jsonl                 # the 16:08–17:08 outage
    python smooth.py own.jsonl --validate      # simulated one-hour outages
    python smooth.py own.jsonl --waypoints     # turns at filed waypoints too
"""

import json
import math
import sys
from bisect import bisect_left

import numpy as np

import reconstruct as rc
from plan import bearing, dist, waypoints, xtrack


def heading_at(hdg, t):
    i = np.searchsorted(hdg[:, 0], t)
    return hdg[max(i - 1, 0), 1]


def turns(air, t0, t1):
    """Turns between t0 and t1: (mid-turn time, change in degrees). As in
    live.py (which cannot be imported: it runs on import)."""
    hdg = np.array([(t, h) for t, h, _ in air.hdg if t0 - 60 <= t <= t1 + 60])
    if len(hdg) < 10:
        return []
    grid = np.arange(t0, t1, 5.0)
    h = np.degrees(np.unwrap(np.radians([heading_at(hdg, t) for t in grid])))
    rate = (h[6:] - h[:-6]) / 30
    grid = grid[3:-3]
    out, i = [], 0
    while i < len(rate):
        if abs(rate[i]) > 0.1:
            j = i
            while j < len(rate) and abs(rate[j]) > 0.05:
                j += 1
            a, b = grid[i] - 20, grid[min(j, len(grid) - 1)] + 20
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

R = rc.R
KT = rc.KT
NM = 1852

# Noise (SI units). Tuned on the simulated outages (--validate).
SIGMA_FIX = 50.0  # m, GNSS position
SIGMA_VEL = 1.0  # m/s, ADS-B ground velocity
SIGMA_WAYPOINT = 1.0 * NM  # m, abeam a filed waypoint at mid-turn
Q_POS = 0.5  # m/√s, heading and TAS noise
Q_WIND = 0.2  # m/s/√s: about 23 kt in an hour
Q_BIAS = math.radians(0.002)  # rad/√s
P0_WIND = 30.0  # m/s
P0_BIAS = math.radians(1.0)
SIGMA_LEG = 1.0 * NM  # m, across the filed leg
LEG_EVERY = 60  # s between leg measurements (the offset is persistent, not white)
LEG_GATE = 3.0  # innovations beyond 3σ are ignored (directs, offsets)
LEG_REACH = 15 * NM  # m, farthest from a leg for it to be the aircraft's
STALE = 30  # s between Comm-B headings: no radar interrogating, heading interpolated
Q_STALE = 100.0  # m/√s while interpolated


def ground_rows(ground):
    """ADS-B ground velocity as (t, east, north) in m/s."""
    return [(t, *(rc.vec(gs, trk) * KT)) for t, gs, trk in ground]


class Smoother:
    def __init__(self, fixes, ground, air, t0, t1, outage=None, anchors=(), legs=None, ref=None, window=None):
        """From t0 to t1, one-second steps. Measurements inside `outage`
        (a, b) are dropped. `anchors`: (t, lat, lon) waypoint fixes.
        `legs`: the filed route [(name, (lat, lon))]; within `window` (a, b),
        every LEG_EVERY s, the leg nearest the previous estimate `ref` (a
        Smoother) gives a cross-track measurement of 0."""
        self.air, self.t0, self.t1 = air, t0, t1
        self.legs = []
        if legs and ref is not None and window:
            for t in range(int(window[0]) + LEG_EVERY, int(window[1]), LEG_EVERY):
                p = ref.at(t)
                best = None
                for (na, a), (nb, b) in zip(legs, legs[1:]):
                    xt, f = xtrack(p, a, b)
                    if 0 <= f <= 1 and abs(xt) * NM < LEG_REACH and (best is None or abs(xt) < abs(best[0])):
                        best = (xt, a, b, f"{na}-{nb}")
                if best:
                    self.legs.append((t, best[1], best[2], best[3]))
        keep = (lambda t: not (outage[0] < t < outage[1])) if outage else (lambda t: True)
        self.fixes = [f for f in fixes if t0 <= f[0] <= t1 and keep(f[0])]
        self.ground = [g for g in ground_rows(ground) if t0 <= g[0] <= t1 and keep(g[0])]
        self.anchors = list(anchors)

    def prepare_heading(self):
        """Post-flight, the heading after a gap in Comm-B is known too: it is
        interpolated (unwrapped) instead of held. `gap(t)`: seconds between
        the samples around t."""
        h = self.air.hdg
        self.ht = np.array([x[0] for x in h])
        self.hv = np.degrees(np.unwrap(np.radians([x[1] for x in h])))

    def heading(self, t):
        i = int(np.searchsorted(self.ht, t))
        if i == 0 or i == len(self.ht):
            return self.hv[min(i, len(self.ht) - 1)] % 360, 0.0
        t0, t1 = self.ht[i - 1], self.ht[i]
        f = (t - t0) / (t1 - t0)
        return (self.hv[i - 1] + f * (self.hv[i] - self.hv[i - 1])) % 360, t1 - t0

    def air_vector(self, t, lat, lon, bias):
        mag, gap = self.heading(t)
        hdg_raw, tas = self.air.at(t, math.degrees(lat), math.degrees(lon))
        # air.at gives the true heading of the latest sample: keep its declination.
        declination = hdg_raw - rc.Air.latest(self.air.th, self.air.hdg, t)[1]
        h = math.radians(mag + declination) + bias
        v = tas * KT
        return v * math.sin(h), v * math.cos(h), gap

    def run(self):
        self.prepare_heading()
        f0 = self.fixes[0]
        x = np.array([math.radians(f0[1]), math.radians(f0[2]), 0.0, 0.0, 0.0])
        P = np.diag([(SIGMA_FIX / R) ** 2, (SIGMA_FIX / R) ** 2, P0_WIND**2, P0_WIND**2, P0_BIAS**2])
        # Measurements by second.
        events = {}
        for t, la, lo in self.fixes:
            events.setdefault(round(t), []).append(("pos", math.radians(la), math.radians(lo), SIGMA_FIX))
        for t, la, lo in self.anchors:
            events.setdefault(round(t), []).append(("pos", math.radians(la), math.radians(lo), SIGMA_WAYPOINT))
        for t, e, n in self.ground:
            events.setdefault(round(t), []).append(("vel", e, n))
        for t, a, b, _ in self.legs:
            events.setdefault(t, []).append(("leg", a, b))
        self.rejected = 0

        times = np.arange(round(f0[0]), round(self.t1) + 1)
        xs_f, Ps_f, xs_p, Ps_p, Fs = [], [], [], [], []
        dt = 1.0
        for k, t in enumerate(times):
            if k > 0:
                lat, lon, we, wn, b = x
                ae, an, gap = self.air_vector(t - 1, lat, lon, b)
                q_pos = Q_POS if gap < STALE else Q_STALE
                c = math.cos(lat)
                x = x + np.array([(an + wn) * dt / R, (ae + we) * dt / (R * c), 0, 0, 0])
                F = np.eye(5)
                F[0, 3] = dt / R
                F[0, 4] = -ae * dt / R  # d(an)/db = -ae
                F[1, 2] = dt / (R * c)
                F[1, 4] = an * dt / (R * c)  # d(ae)/db = an
                F[1, 0] = (ae + we) * dt * math.tan(lat) / (R * c)
                Q = np.diag([(q_pos / R) ** 2 * dt, (q_pos / (R * c)) ** 2 * dt,
                             Q_WIND**2 * dt, Q_WIND**2 * dt, Q_BIAS**2 * dt])
                P = F @ P @ F.T + Q
                Fs.append(F)
            xs_p.append(x.copy())
            Ps_p.append(P.copy())
            for m in events.get(int(t), []):
                if m[0] == "pos":
                    _, la, lo, s = m
                    c = math.cos(x[0])
                    H = np.zeros((2, 5))
                    H[0, 0] = R
                    H[1, 1] = R * c
                    z = np.array([R * (la - x[0]), R * c * (lo - x[1])])
                    Rm = np.eye(2) * s**2
                elif m[0] == "leg":
                    _, a, b = m
                    p = (math.degrees(x[0]), math.degrees(x[1]))
                    xt, _ = xtrack(p, a, b)
                    c = math.radians(bearing(p, b))
                    H = np.zeros((1, 5))
                    H[0, 0] = R * -math.sin(c)  # right normal (east, north) = (cos c, -sin c)
                    H[0, 1] = R * math.cos(x[0]) * math.cos(c)
                    z = np.array([-xt * NM])
                    Rm = np.eye(1) * SIGMA_LEG**2
                    if abs(z[0]) > LEG_GATE * math.sqrt((H @ P @ H.T + Rm)[0, 0]):
                        self.rejected += 1
                        continue
                else:
                    _, e, n = m
                    lat, lon, we, wn, b = x
                    ae, an, _ = self.air_vector(t, lat, lon, b)
                    H = np.zeros((2, 5))
                    H[0, 2] = 1
                    H[0, 4] = an
                    H[1, 3] = 1
                    H[1, 4] = -ae
                    z = np.array([e - (ae + we), n - (an + wn)])
                    Rm = np.eye(2) * SIGMA_VEL**2
                S = H @ P @ H.T + Rm
                K = P @ H.T @ np.linalg.inv(S)
                x = x + K @ z
                P = (np.eye(5) - K @ H) @ P
            xs_f.append(x.copy())
            Ps_f.append(P.copy())

        # Rauch–Tung–Striebel, backward.
        n = len(times)
        xs_s, Ps_s = [None] * n, [None] * n
        xs_s[-1], Ps_s[-1] = xs_f[-1], Ps_f[-1]
        for k in range(n - 2, -1, -1):
            C = Ps_f[k] @ Fs[k].T @ np.linalg.inv(Ps_p[k + 1])
            xs_s[k] = xs_f[k] + C @ (xs_s[k + 1] - xs_p[k + 1])
            Ps_s[k] = Ps_f[k] + C @ (Ps_s[k + 1] - Ps_p[k + 1]) @ C.T
        self.times = times
        self.forward = np.array(xs_f)
        self.smoothed = np.array(xs_s)
        self.sigma = np.array([math.sqrt(max(p[0, 0], p[1, 1] * math.cos(x[0]) ** 2)) * R
                               for p, x in zip(Ps_s, xs_s)])
        return self

    def at(self, t, which="smoothed"):
        a = getattr(self, which)
        k = min(max(int(round(t)) - int(self.times[0]), 0), len(self.times) - 1)
        return math.degrees(a[k, 0]), math.degrees(a[k, 1])

    def state(self, t, which="smoothed"):
        a = getattr(self, which)
        k = min(max(int(round(t)) - int(self.times[0]), 0), len(self.times) - 1)
        we, wn, b = a[k, 2:]
        return math.hypot(we, wn) / KT, math.degrees(math.atan2(-we, -wn)) % 360, math.degrees(b)


def truth_at(fixes, tf, t):
    i = bisect_left(tf, t)
    f = fixes[min(i, len(fixes) - 1)]
    return f if abs(f[0] - t) < 3 else None


def errors(sm, fixes, a, b):
    tf = [f[0] for f in fixes]
    out = {"forward": [], "smoothed": []}
    for t in np.arange(a + 60, b, 60):
        f = truth_at(fixes, tf, t)
        if f is None:
            continue
        for which in out:
            out[which].append(dist(sm.at(f[0], which), f[1:]) / NM)
    return {k: np.array(v) for k, v in out.items()}


def anchors_for(air, wps, sm_or_path, t0, t1):
    """Mid-turn times between t0 and t1, near a filed waypoint: (t, lat, lon)."""
    out = []
    for mid, change in turns(air, t0, t1):
        p = sm_or_path(mid)
        name, q = min(wps, key=lambda w: dist(p, w[1]))
        d = dist(p, q) / NM
        if d <= 12:
            out.append((mid, q[0], q[1], name, d, change))
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "own.jsonl"
    rows = rc.load(path)
    fixes, ground, air_, alt = rc.series(rows)
    air = rc.Air(air_, alt)
    tf = [f[0] for f in fixes]

    if "--validate" in sys.argv:
        print("Simulated one-hour outages: error to GNSS (NM), median / max over the hour")
        print("start     forward (DR)     smoothed        smoothed at mid-outage")
        for hhmm in ["17:30", "18:30", "19:30", "20:30", "21:30", "22:30", "23:30", "00:30"]:
            h, m = map(int, hhmm.split(":"))
            a = 1794700800 + (h * 3600 + m * 60 if h >= 12 else 86400 + h * 3600 + m * 60)  # 15 Nov 00:00 UTC
            b = a + 3600
            if truth_at(fixes, tf, a) is None or truth_at(fixes, tf, b) is None:
                continue
            sm = Smoother(fixes, ground, air, a - 1200, b + 1200, outage=(a, b)).run()
            e = errors(sm, fixes, a, b)
            mid = e["smoothed"][len(e["smoothed"]) // 2]
            print(f"{hhmm}     {np.median(e['forward']):5.1f} / {e['forward'].max():5.1f}   "
                  f"{np.median(e['smoothed']):5.1f} / {e['smoothed'].max():5.1f}   {mid:5.1f}")
        return

    # The real outage.
    gaps = [(x, y) for x, y in zip(fixes, fixes[1:]) if y[0] - x[0] > 1800]
    (a, *_), (b, *_) = gaps[0]
    print(f"Outage {rc.hms(a)} → {rc.hms(b)}")
    wps = waypoints()
    sm = Smoother(fixes, ground, air, a - 1200, b + 1200).run()
    print("\nWaypoints at mid-turn (not used by the smoother): distance from each estimate")
    found = anchors_for(air, wps, lambda t: sm.at(t), a, b)
    for mid, la, lo, name, d, change in found:
        fwd = dist(sm.at(mid, "forward"), (la, lo)) / NM
        print(f"  {name:6s} {rc.hms(mid)} turn {change:+5.1f}°: forward {fwd:5.1f} NM, smoothed {d:4.1f} NM")
    w0, w1 = sm.state(a), sm.state(b)
    print(f"\nSmoothed wind {w0[0]:.0f} kt from {w0[1]:.0f}° at {rc.hms(a)}, {w1[0]:.0f} kt from {w1[1]:.0f}° at {rc.hms(b)}; "
          f"heading bias {w0[2]:+.2f}° → {w1[2]:+.2f}°")
    print(f"Largest 1-sigma position uncertainty: {sm.sigma.max() / NM:.1f} NM")

    result = sm
    if "--waypoints" in sys.argv:
        anchors = [(mid, la, lo) for mid, la, lo, *_ in found]
        result = Smoother(fixes, ground, air, a - 1200, b + 1200, anchors=anchors).run()
        moved = max(dist(sm.at(t), result.at(t)) for t in range(int(a), int(b), 30)) / NM
        print(f"With the {len(anchors)} waypoints: moves by up to {moved:.1f} NM, "
              f"sigma up to {result.sigma.max() / NM:.1f} NM")

    out = [{"t": int(t), "lat": round(math.degrees(x[0]), 5), "lon": round(math.degrees(x[1]), 5),
            "sigma_nm": round(s / NM, 2)}
           for t, x, s in zip(result.times, result.smoothed, result.sigma) if a <= t <= b][::10]
    json.dump(out, open("smoothed.json", "w"))
    print(f"smoothed.json: {len(out)} points")


if __name__ == "__main__":
    main()
