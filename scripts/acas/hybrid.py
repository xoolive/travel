"""How often our TCAS re-interrogates each tracked aircraft, per 20 minutes:
share of intervals near 1, 2, 5 and 10 s. Bins overlapping the GNSS outage
are marked (OUT below, written for AF162: 16:08:35-17:08:45 UTC).

    python hybrid.py UPLINK.jsonl [OWN_ICAO24]
"""
import json, sys, collections, datetime
import numpy as np
OWN = sys.argv[2] if len(sys.argv) > 2 else "39d2b1"
t = lambda x: datetime.datetime.fromtimestamp(x, datetime.UTC).strftime("%H:%M")
uf0 = collections.defaultdict(list)
for l in open(sys.argv[1]):
    if '"uf":"0"' in l:
        r = json.loads(l)
        if r["icao24"] != OWN: uf0[r["icao24"]].append(r["timestamp"])
real = {k: np.array(v) for k, v in uf0.items() if len(v) >= 10}
OUT = (1794758915, 1794762525)  # 16:08:35–17:08:45
# per 20-min bin: intervals between consecutive interrogations of the same target (< 30 s)
bins = collections.defaultdict(list)
for k, ts in real.items():
    d = np.diff(ts); m = d < 30
    for a, dd in zip(ts[1:][m], d[m]): bins[int(a // 1200 * 1200)].append(dd)
print("UTC    n     ~1s   ~2s   ~5s   ~10s  (share of intervals)")
for b in sorted(bins):
    d = np.array(bins[b])
    f = lambda lo, hi: np.mean((d >= lo) & (d < hi))
    tag = " <- GNSS outage" if OUT[0] - 1200 < b < OUT[1] else ""
    print(f"{t(b)} {len(d):6d}  {f(0.7,1.3):.2f}  {f(1.7,2.3):.2f}  {f(4.5,5.5):.2f}  {f(9.3,10.7):.2f}{tag}")
