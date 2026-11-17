"""Aircraft tracked by our own TCAS: every address with at least 10 UF 0
interrogations, first/last time, median interval, DF 0/16 replies heard by
jet1090 in that window (with their altitudes), callsign, and the aircraft
database entry (~/Documents/data/aircraft_db.csv.gz).

    python targets.py UPLINK.jsonl JET1090.jsonl [OWN_ICAO24] > targets.txt
"""
import json, sys, collections, datetime, gzip, csv, os
import numpy as np
OWN = sys.argv[3] if len(sys.argv) > 3 else "39d2b1"
t = lambda x: datetime.datetime.fromtimestamp(x, datetime.UTC).strftime("%H:%M:%S")
up = [json.loads(l) for l in open(sys.argv[1])]
uf0 = collections.defaultdict(list)
for r in up:
    if r["uf"] == "0" and r["icao24"] != OWN:
        uf0[r["icao24"]].append(r["timestamp"])
counts = collections.Counter({k: len(v) for k, v in uf0.items()})
print("UF0 addresses:", len(counts), " with >=10:", sum(1 for v in counts.values() if v >= 10),
      " singletons:", sum(1 for v in counts.values() if v == 1))
print("interrogations to addresses with >=10:", sum(v for v in counts.values() if v >= 10), "of", sum(counts.values()))
# replies on 1090
rep = collections.defaultdict(list)  # icao -> (t, df, altitude)
cs = {}
with open(sys.argv[2]) as f:
    for l in f:
        if '"df":"0"' in l or '"df":"16"' in l or '"callsign"' in l or '"df":0' in l or '"df":16' in l:
            r = json.loads(l)
            if r.get("callsign"): cs[r["icao24"]] = r["callsign"].strip()
            if str(r.get("df")) in ("0", "16"):
                rep[r["icao24"]].append((r["timestamp"], str(r["df"]), r.get("altitude")))
db = {}
p = os.path.expanduser("~/Documents/data/aircraft_db.csv.gz")
with gzip.open(p, "rt") as f:
    rd = csv.DictReader(f)
    keys = rd.fieldnames
    for row in rd:
        db[row[keys[0]].lower()] = row
print("db fields", keys[:8])
real = [k for k, v in counts.items() if v >= 10]
print(f"\n{'icao':6} {'n':>5} {'first':>8} {'last':>8} {'dt med':>6}  replies(alt)  callsign  aircraft")
for k in sorted(real, key=lambda k: uf0[k][0]):
    ts = np.array(uf0[k]); d = np.diff(ts)
    rr = [x for x in rep.get(k, []) if ts[0] - 5 <= x[0] <= ts[-1] + 5]
    alts = [x[2] for x in rr if x[2]]
    row = db.get(k, {})
    desc = " ".join(str(row.get(c, "")) for c in keys[1:5] if row.get(c))
    print(f"{k} {len(ts):5d} {t(ts[0])} {t(ts[-1])} {np.median(d) if len(d) else 0:6.1f}  {len(rr):4d} {('%s–%s' % (min(alts), max(alts))) if alts else '':13s} {cs.get(k, ''):8s} {desc[:50]}")
