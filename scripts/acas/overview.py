"""ACAS uplinks of an uplink1030 recording, per 20 minutes: UF 0
interrogations (to us / to others, distinct targets, how many also heard on
1090) and UF 16 ACAS broadcasts (ours / others').

    python overview.py UPLINK.jsonl [OWN_ICAO24]
"""
import json, sys, collections, datetime
import numpy as np
OWN = sys.argv[2] if len(sys.argv) > 2 else "39d2b1"
t = lambda x: datetime.datetime.fromtimestamp(x, datetime.UTC).strftime("%H:%M")
rows = [json.loads(l) for l in open(sys.argv[1])]
acas = [r for r in rows if r["uf"] in ("0", "16")]
print("span", t(rows[0]["timestamp"]), t(rows[-1]["timestamp"]))
# RSSI split
for lab, sel in (("UF0 to us", lambda r: r["uf"] == "0" and r["icao24"] == OWN),
                 ("UF0 to others", lambda r: r["uf"] == "0" and r["icao24"] != OWN),
                 ("UF16 from us", lambda r: r["uf"] == "16" and r["icao24"] == OWN),
                 ("UF16 from others", lambda r: r["uf"] == "16" and r["icao24"] != OWN)):
    x = [r["metadata"][0]["rssi"] for r in acas if sel(r)]
    if x: print(f"{lab:18s} n={len(x):6d} rssi p10/50/90 {np.percentile(x,10):.1f} {np.percentile(x,50):.1f} {np.percentile(x,90):.1f}")
# per 20 min
bins = collections.defaultdict(lambda: collections.Counter())
tg = collections.defaultdict(set); snd = collections.defaultdict(set); seen = collections.defaultdict(set)
for r in acas:
    b = int(r["timestamp"] // 1200 * 1200)
    if r["uf"] == "0":
        bins[b]["to_us" if r["icao24"] == OWN else "to_others"] += 1
        if r["icao24"] != OWN:
            tg[b].add(r["icao24"])
            if r.get("seen_1090"): seen[b].add(r["icao24"])
    else:
        bins[b]["b_us" if r["icao24"] == OWN else "b_others"] += 1
        if r["icao24"] != OWN: snd[b].add(r["icao24"])
print("\nUTC   UF0→us UF0→others(targets, on1090) UF16 bcast us/others(senders)")
for b in sorted(bins):
    c = bins[b]
    print(f"{t(b)}  {c['to_us']:6d}  {c['to_others']:6d} ({len(tg[b]):3d}, {len(seen[b]):3d})   {c['b_us']:4d} / {c['b_others']:4d} ({len(snd[b])})")
