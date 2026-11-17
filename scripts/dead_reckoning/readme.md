# Estimating our position without GNSS

AF162 (AFR162, F-HUVR, `39d2b1`), Paris CDG → Tokyo Haneda, 15 November 2026,
receiver on board. Recording `~/20261115_AA89665103_LFPG_RJTT.jsonl` (jet1090)
and the `jet1090` Redis channel; flight plan
`~/20261115_AA89675273_LFPG_RJTT.flight.json` (B2B, AFR162).

## What happens

Over the Black Sea and Turkey the aircraft loses GNSS (jamming): a first
outage 15:50–15:53 UTC (3 min), then **16:08:35–17:08:45 (one hour)**.
During an outage:

- ADS-B NACp goes to 0, then airborne position (BDS 0,5) and airborne
  velocity (BDS 0,9) stop altogether: no position, no ground speed or track;
- BDS 5,0 still gives TAS and roll, but its track and ground speed are empty
  (they come from GNSS);
- BDS 6,0 still gives the **magnetic heading**, IAS, Mach and vertical rates,
  about once a second (the aircraft keeps being interrogated by radars);
- the barometric altitude (DF 0/4/20) and BDS 4,0 / 6,2 (selected altitude
  and heading) are still there.

So we know where the aircraft points and how fast it moves through the air,
but neither the wind nor where it is.

## Method

1. **Last trusted position.** Airborne position messages (TC 11) are kept
   while NACp ≥ 8. The last one before the gap is the starting point.

2. **Air vector.** The BDS 6,0 heading is magnetic: the declination comes from
   the World Magnetic Model (`pygeomag`), about 6.5° E over the Black Sea,
   giving the true heading. The speed is the BDS 5,0 TAS; when none is recent,
   Mach and pressure altitude give TAS in the standard atmosphere
   (`openap.aero.mach2tas`).

3. **Wind.** While GNSS still works, ground vector (ADS-B ground speed and
   track) minus air vector (TAS, true heading) is the wind. It is averaged over
   the last 10 minutes before the outage: 56 kt from 265° at 16:08, with a
   spread of only 2–3 kt over 1,250 samples.

4. **Dead reckoning.** From the last position, every second: position +=
   (air vector + wind) × 1 s, with the heading and TAS of the latest Comm-B
   replies.

5. **The filed route.** Field 15 of the flight plan, resolved by Travel
   against the AIRAC 2606 AIXM data (`Travel --plan FILE`), gives the legs.
   The aircraft flies them closely: with GNSS, 0–2 NM from the legs after
   INVED, 5–11 NM on the 350 NM UMVEG → INVED leg.

6. **Hold the estimate on the leg.** The published position is the dead
   reckoning moved onto the nearest leg (within 10 NM), keeping its progress
   along it: the lateral error is dropped, only the along-track error stays.

7. **Waypoints as position fixes.** A turn is found in the heading: a rate
   above 0.1°/s, settled on both sides, more than 5° in all. For a fly-by
   turn the aircraft is abeam the waypoint at **mid-turn** (heading halfway
   between before and after). If the estimate is then within 12 NM of a filed
   point, the aircraft is taken to be over it: the position is reset there,
   and the gap divided by the time since the previous anchor is added to the
   wind from then on.

8. **Next point.** Among the filed points ahead (bearing within 30° of the
   estimated track), the nearest gives the distance and ETA.

## Results on the one-hour outage

| Waypoint | Mid-turn (UTC) | Heading (magnetic) | Raw dead reckoning off by | NM profile |
|---|---|---|---|---|
| UDROS | 16:20:07 | 119.9° → 102.4° | 3.7 NM (behind, 1 NM right) | 16:20:10 |
| CRM | 16:49:15 | 103° → 86° | 10.4 NM (mostly to the left) | 16:50:16 |
| TBN | 17:05:03 | 88° → 82° | 5.7 NM | — |

- **At the end of the outage, the estimate was about 0.4 NM from the first
  GNSS position** (17:08:45), ahead along the route, under 0.1 NM across.
- Holding the estimate on the legs did most of the work. Left alone, dead
  reckoning drifted to the **left** of the legs, up to 10 NM: its track was
  steadily 2–3° left of the bearing to the next point. This looks like a
  heading or declination bias rather than wind: the "wind corrections" at
  the three waypoints (19 kt from 283°, 21 kt from 8°, 22 kt from 54°) turn
  around, which a real wind would not do. They absorb the bias.
- Along the route, the waypoint resets keep the error to a few NM. The
  stronger jet stream over the Black Sea (87 kt from 268° after UDROS, against
  56 kt over Romania) explains the first along-track error.
- Our ETA at CRM (16:49:28) was closer to the actual turn (16:49:15) than the
  Network Manager's profile (16:50:16).
- **Flighty** keeps a track for the flight in its map cache
  (`~/Library/Containers/com.flightyapp.flighty/Data/Library/Application Support/map-state-repository/<flight id>.pb`,
  protobuf). With GNSS it agrees with our ADS-B across the track and lags
  0.6–1.2 NM along it (about 6 s). It keeps having positions during the
  outage (multilateration or projection along the route, unknown); corrected
  for the lag, it agreed with the UDROS fix, and within about a NM after it.

Earlier checks, before the leg constraint: outages simulated on purpose
earlier in the flight gave 0.5–2.2 NM after 5 minutes, 1.5–4.7 NM after 10,
1.7–7.1 NM after 20; the 15:51 outage (3 minutes) ended 0.5 NM off.

## Limits and known problems

- **During a turn**, the raw dead reckoning can be more than 10 NM from every
  leg (at CRM, 16:49:39–16:50:39): the estimate is then published
  unconstrained and jumps aside for a minute. Better: keep the leg after the
  last confirmed waypoint, whatever the distance.
- **Resets jump**: a turn is confirmed 20–30 s after it ends, and the
  position since the turn is recomputed at once. Better: blend the
  correction over a few seconds.
- The lateral bias should be estimated (e.g. from the cross-track drift
  between two waypoints) and removed, instead of being folded into the wind.
- A waypoint is identified only if the aircraft turns there, flies the
  filed route, and the estimate is close enough. Straight through a point, or
  on a direct, there is nothing to anchor to (only the leg constraint).
- The flight plan matters: the first plan used (AFR282, another flight) put
  the route 80–100 NM off over Hungary and Romania.
- Weather forecasts (GRIB winds) would help between waypoints.

## Post-flight: Kalman filter and smoother (`smooth.py`)

The live method above is not a Kalman filter. It holds the wind measured
before the outage, puts the estimate on the legs, and resets it at turns.
After the flight, the GNSS fixes after the outage are known too. A two-pass
filter uses both ends:

- **State:** latitude, longitude, wind (east, north), heading bias.
- **Input:** the air vector, from the BDS 6,0 heading plus declination and
  the BDS 5,0 TAS (or Mach).
- **Measurements:**
  - GNSS positions (NACp ≥ 8), σ 50 m;
  - ADS-B ground velocity, σ 1 m/s;
  - all before and after the outage.
- **Pass 1:** an extended Kalman filter, forward, one-second steps. Alone, it
  is dead reckoning with the wind estimated before the outage.
- **Pass 2:** a Rauch–Tung–Striebel smoother, backward. It brings the fixes
  after the outage back in time, giving the wind and bias that join both
  ends. A wind change during the outage is spread as a random walk.
- **Tuning:**
  - wind random walk 0.2 m/s/√s (about 23 kt in an hour);
  - bias prior σ 1°.
- **Gaps in Comm-B:** when no radar interrogates the aircraft (18:38–18:57,
  19 min with no BDS 6,0), the heading is interpolated between the samples
  around the gap, not held. The position noise is raised meanwhile.
- **No flight plan needed.** Waypoints at mid-turn can be added as position
  measurements with σ 1 NM (`--waypoints`). This is optional and changed
  little here.

**Validation:** GNSS removed for one hour, on eight windows where GNSS
worked, compared with the real track every minute. Error in NM, median / max:

| Start | Forward (dead reckoning) | Smoothed |
|---|---|---|
| 17:30 | 7.8 / 18.9 | 0.4 / 0.7 |
| 18:30 | 5.3 / 20.7 | 1.2 / 2.7 |
| 19:30 | 10.4 / 22.0 | 0.9 / 1.7 |
| 20:30 | 6.7 / 18.9 | 0.7 / 1.8 |
| 21:30 | 2.6 / 8.2 | 0.7 / 1.2 |
| 22:30 | 2.0 / 8.4 | 0.8 / 1.2 |
| 23:30 | 5.1 / 8.5 | 0.5 / 1.5 |
| 00:30 | 7.1 / 22.1 | 0.5 / 0.7 |

- The worst windows are in the middle of the outage, or where the wind
  changes inside it.
- About 10 % of the errors are outside 2σ, so the uncertainty is slightly
  optimistic.

**The real outage, 16:08:35–17:08:45:**

- The waypoints were not used, so they are an independent check. Distance
  of the estimate from each filed point at mid-turn:
  - UDROS: forward 2.2 NM, smoothed **0.7 NM**;
  - CRM: forward 16.9 NM, smoothed **1.0 NM**;
  - TBN: forward 27.7 NM, smoothed 0.1 NM (4 minutes before the end).
- Smoothed wind: 75 kt from 265° at the start, 64 kt from 299° at the end.
- Heading bias −0.7°.
- σ is at most 1.7 NM.
- Adding the three waypoints moves the track by at most 0.9 NM.
- Output: `smoothed.json` (t, lat, lon, sigma_nm every 10 s).

**Earlier tuning, for the record:**
- A wider bias prior (3°) traded heading bias against wind (−6° to +5°
  from one window to another).
- Holding the last heading through the 18:38 Comm-B gap gave 9.7 NM.

**Filed legs as measurements: tried, worse.** The idea was that aircraft
mostly fly their legs (airways along navaids), so the smoother could use the
legs.

- **How it was tried:**
  - every 60 s during the outage, the cross-track distance to the filed leg
    nearest the previous estimate is a measurement of 0, with σ 1 NM;
  - innovations beyond 3σ are ignored;
  - two iterations;
  - legs from `route.tsv` (`Travel --plan`, X-Plane airways included).
- **Result on the same eight windows:** the median error went from 0.71 NM
  to 2.2–3.6 NM (σ 0.5–2 NM, every 30–120 s), and the worst error reached
  4–15 NM.
- **Why:**
  - the real track is often several NM off the filed legs: the median
    distance is 2–3 NM on half the windows, because of the ATC offsets over
    China (exactly 3 NM, then 5 NM) and directs;
  - a cross-track error that persists is not white noise, and the gating
    does not catch a steady 3 NM.
- **When it helps:** only when the ends do not constrain the track, so live
  or after a long outage; there the leg-holding of `live.py` stays.
  Post-flight, two GNSS ends and the air data beat the flight plan.

**Live:** a backward pass needs the fixes after the outage. A fixed-lag
smoother would correct only the last few minutes, so live stays with the leg
and waypoint method.

## Live, and what Travel shows

`live.py` reads the recording for the history, then subscribes to `jet1090`.
Every 10 s it recomputes everything (turns, wind, position); every 2 s it
moves the position on and publishes — only while no trusted position is less
than 20 s old — on the Redis channel `datalink-estimated`:

```json
{"timestamp": 1794760958.91, "icao24": "39d2b1", "latitude": 41.63637,
 "longitude": 35.18574, "altitude": 37000, "track": 106.7,
 "groundspeed": 576, "estimated": "dead-reckoning"}
```

Travel subscribes to `datalink-*` and reads messages by content: one with
`icao24` and a position goes to that aircraft. `track` is needed for the
aircraft icon (without it Travel draws a dot). Nothing goes on `jet1090`, so
uplink1030 and the recording only see real data. Travel does not mark these
positions as estimated yet.

## Scripts

In this folder, **`~/Documents/code/travel/scripts/dead_reckoning/`**, next to
this readme. `own.jsonl` and the outputs (`current.json`, `smoothed.json`)
are not committed:

| File | What |
|---|---|
| `reconstruct.py` | the method: messages of one aircraft, air vector, wind, propagation; run alone, validates on simulated and real outages |
| `plan.py` | the filed route (`route.txt`, coordinates from the AIRAC cache) and comparison of the track with its legs |
| `route.tsv` | route points with coordinates (`Travel --plan FILE` output, X-Plane fallback marked); preferred by `plan.py` over `route.txt` |
| `route.txt` | point names of the route, as printed by `Travel --plan FILE` |
| `smooth.py` | post-flight: EKF forward, RTS smoother backward; `--validate` (simulated outages), `--waypoints` |
| `live.py` | live estimation from the recording + Redis, turn detection, leg holding, publishing |
| `compare.py` | our track and estimate against Flighty's |
| `flighty_pb.py` | raw reader of Flighty's map-state protobuf |

Requirements: `uv` (openap, pygeomag, redis), the AIRAC index built by
Travel (`~/Library/Caches/travel/AIRAC_*.json`), Redis on 127.0.0.1:6379.

For another flight:

1. set the aircraft address (`ICAO` in `reconstruct.py`, `"39d2b1"` in
   `live.py`, `FLIGHT` UUID in `compare.py`);
2. write the route:
   `.build/release/Travel --plan ~/…flight.json | tail -1 > scripts/dead_reckoning/route.txt`
   (from the travel folder);
3. extract the aircraft from the recording and run:

```sh
cd ~/Documents/code/travel/scripts/dead_reckoning
grep '"39d2b1"' ~/RECORDING.jsonl > own.jsonl
# offline: validation and the current outage
uv run --no-project --with openap --with pygeomag python reconstruct.py own.jsonl
# live, for 3 hours, publishing on datalink-estimated
uv run --no-project --with openap --with pygeomag --with redis python live.py 10800 own.jsonl
# post-flight smoother (the recording is now .jsonl.zst)
zstdcat ~/20261115_AA89675273_LFPG_RJTT.jsonl.zst | grep '"39d2b1"' > own.jsonl
uv run --no-project --with openap --with pygeomag python smooth.py own.jsonl
```

Some time ranges are written for this flight (the simulated outages in
`reconstruct.py`, the UDROS window in `compare.py`, the decimal year 2026.87
for the magnetic model).
