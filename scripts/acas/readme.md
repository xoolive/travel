# Air-to-air (ACAS) on board: AF162, 15 November 2026

AF162 (AFR162, F-HUVR, `39d2b1`), Paris CDG → Tokyo Haneda.

- **1030 MHz:** uplink1030 on an Airspy in the cabin
  (`~/20261115_AA89665103_LFPG_RJTT_uplink.jsonl`).
- **1090 MHz:** jet1090 on a low-gain RTL-SDR
  (`~/20261115_AA89665103_LFPG_RJTT.jsonl`).
- Figures below cover 12:44–21:51 UTC.

## What is received on 1030 MHz

| Format | Count | What it is |
|---|---|---|
| UF 0 | 81,474 | TCAS interrogations. **All from our own TCAS**: none addressed to us, steady level (median −30.5 dB, 10–90 %: −32.0 to −26.7) |
| UF 16 | 5,274 | ACAS broadcasts (`acas_b`, MU starting `0x32`, sender address in the message, AP `ffffff`). 5,242 are ours, about one every 10 s. Only 43 come from 15 other aircraft, all around CDG (AFR60K, JAL45, UAE65W, HOP78GA…). One frame decoded as `unknown` (14:13:22) is one of ours with a one-bit error |
| UF 24 | 26,507 | looks like noise: `ffff…` patterns, random addresses |
| UF 4/5/11 | 1,918 | ground radar interrogations, mostly on the ground (see `docs/radars-onboard.md`) |
| UF 20/21 | 4 | — |

Other aircraft's interrogations of us are not heard. Our own transmitter,
a few metres away, dominates the receiver.

## Who our TCAS tracked

UF 0 carries the address of the interrogated aircraft (in the parity
field). About 2,600 addresses appear:

- about 1,300 have at least 10 interrogations: real tracks;
- 342 appear once, and most of the rest a few times: bit errors.

Distinct targets per 20 minutes:

| Phase | Targets per 20 min |
|---|---|
| CDG, climb (13:20–13:40) | 265–354 |
| Germany, Austria (14:20–14:40) | 536–600 |
| Hungary to the Black Sea (15:00–16:00) | 211–330 |
| Turkey, Caucasus (16:20–17:40) | 43–97 |
| Caspian, Central Asia (18:00–21:00) | 8–35 |
| Xinjiang, Gansu (21:20) | 36 |

Arriving in China, the targets are Cathay (B-KPA, B-KPU, B-LRK, B-LXN…),
Air China, Hainan, China Eastern and China Southern, and Asiana 747s.

Aircraft flying alongside us for hours, probably on the same airways:

| Aircraft | Tracked (UTC) | Interrogations, median interval |
|---|---|---|
| China Eastern A330 B-1073 (`781393`) | 17:19–21:46 | 1,194, 10 s |
| LOT 787-8 SP-LRH (`48ae07`) | 15:43–21:52 | 269, 7 s |
| ITA A350 EI-IFB (`4cad45`) | 15:55–21:39 | 95, 3 s |
| Uzbekistan A321neo UK32112 (`507cb9`) | 19:31–21:51 | 612, 8 s |
| Turkish A321neo TC-LTE (`4bb285`) | 17:21–20:09 | 311, 2 s |
| Singapore A350 9V-SMP (`76cdb0`) | 15:09–18:04 | 193, 4.5 s |
| ITA A330neo EI-HJP, ITY758 (`4cadc8`) | 15:32–18:27 | 1,003, 5 s |
| Cargo 747-8 OO-LFC (`44b0c3`) | 15:16–19:58, in episodes | 79, 1 s |

Some addresses span hours with very few interrogations (`2cf8aa`, `2cf872`,
`2cf89d`, with medians of minutes): probably bit errors, not aircraft.

**On 1090 MHz** only 38 of these aircraft were also heard replying (DF 0/16),
almost all near Paris. The low-gain receiver in the cabin hears almost no
other aircraft in cruise, so there are no altitudes for the encounters.

**No resolution advisory all flight.**

- There are no ACAS coordination messages (UF 16 with UDS 3,0).
- None of the 3,284 BDS 3,0 reports from our transponder (DF 20/21) shows
  `issued_ra: true`.

## The GNSS outage changed how TCAS tracked traffic

How often our TCAS re-interrogates the same aircraft: the share of the
intervals between interrogations (shorter than 30 s) that fall near each
value.

| UTC | ~1 s | ~2 s | ~5 s | ~10 s |
|---|---|---|---|---|
| 14:20 | 0.23 | 0.27 | 0.02 | 0.04 |
| 15:00–15:20 | 0.17–0.22 | 0.17–0.22 | 0.04–0.05 | 0.13 |
| 15:40 (includes the 15:50 outage) | 0.24 | 0.14 | 0.11 | 0.09 |
| 16:00 (outage from 16:08) | 0.25 | 0.14 | 0.16 | 0.07 |
| **16:20–16:40 (no GNSS)** | 0.21–0.25 | 0.06 | **0.33–0.39** | **0.02** |
| 17:00 (GNSS back 17:08) | 0.22 | 0.09 | 0.22 | 0.12 |
| 17:20–17:40 | 0.20–0.22 | 0.09–0.15 | 0.13–0.15 | 0.15–0.24 |
| 19:40–21:00 | 0.06–0.27 | 0.01–0.17 | 0.00–0.01 | 0.27–0.58 |

**Interpretation (not confirmed):**

- **Every 10 s looks like TCAS hybrid surveillance.** Distant, non-threatening
  traffic is tracked from its ADS-B positions, and actively interrogated only
  about every 10 s to validate them.
- **Every 5 s looks like active surveillance at a reduced rate.** Without our
  own GNSS position, ADS-B positions of others cannot be checked against the
  measured range and bearing, so TCAS fell back to it.
- **Every 1 s** would be traffic close enough, or converging, to be tracked
  at the full rate.
- **Every 2 s** may be 1 s tracks with every other interrogation missed by our
  receiver, or a top/bottom antenna alternation: not checked.

As a side effect, jamming GNSS increases the 1030 MHz load around the
aircraft.

To confirm:

- check the thresholds in the TCAS II / hybrid surveillance standards
  (RTCA DO-185B, DO-300);
- look at another flight with an outage.

## Limits

- Only our side of the encounters: we hear our interrogations, not the
  replies of distant aircraft, nor others' interrogations of us.
- Interval medians depend on our decoding. Missed interrogations stretch the
  intervals, and bit errors create false addresses (hence the ≥ 10 filter).
- Without altitudes or positions of the targets, we cannot say how close
  they came.
  - Higher gain on 1090, or an antenna near a window, would add the DF 0
    replies, which carry their altitude.
  - Flighty's map-state cache keeps nearby traffic positions; to cross-check.

## Scripts

In this folder, **`~/Documents/code/travel/scripts/acas/`**:

| File | What |
|---|---|
| `overview.py` | per 20 minutes: UF 0 to us / to others, distinct targets, UF 16 broadcasts ours / others'; RSSI split |
| `targets.py` | every address with ≥ 10 interrogations: times, median interval, 1090 replies and altitudes, callsign, aircraft database entry |
| `hybrid.py` | per 20 minutes: share of re-interrogation intervals near 1, 2, 5, 10 s; GNSS outage bins marked |

Requirements: `uv`, numpy, and the aircraft database
`~/Documents/data/aircraft_db.csv.gz` for `targets.py`.

```sh
cd ~/Documents/code/travel/scripts/acas
UP=~/20261115_AA89665103_LFPG_RJTT_uplink.jsonl
ADSB=~/20261115_AA89665103_LFPG_RJTT.jsonl
uv run --no-project --with numpy python overview.py $UP 39d2b1
uv run --no-project --with numpy python targets.py $UP $ADSB 39d2b1 > targets.txt
uv run --no-project --with numpy python hybrid.py $UP 39d2b1
```

For another flight:

- give the own aircraft address as the last argument;
- set the outage window `OUT` in `hybrid.py` (Unix times).
