# Radars met on board: AF162, 15 November 2026

Receivers in the cabin of AF162 (AFR162, F-HUVR, `39d2b1`), Paris CDG →
Tokyo Haneda: jet1090 on an RTL-SDR at low gain (`rtlsdr-lowgain`, gain 30,
`~/20261115_AA89665103_LFPG_RJTT.jsonl`), uplink1030 on an Airspy
(`~/20261115_AA89665103_LFPG_RJTT_uplink.jsonl`), both on Redis.

## Why Travel shows no radar in cruise

Travel places an interrogator on a catalogue site (`Resources/radars.csv`)
once **at least 3 located aircraft** (or 10 % of them) are explained by that
site, each with at least 2 interrogations heard or 5 DF 11 replies naming the
code (`Dataset.fitSites`).

In cruise this never happens:

| UTC | Other aircraft heard (10 min) | with a position | with DF 11 naming a radar |
|---|---|---|---|
| 12:40–13:40 (CDG, climb) | 13–32 | 9–22 | 3–14 |
| 13:50 | 14 | 3 | 6 |
| 14:00 onwards | 2–9 | 0–2 | 0–2 |

The low-gain receiver inside the cabin hears almost only our own aircraft.
uplink1030 keeps running but in cruise mostly hears ACAS (UF 0/16) and UF 24,
with very few ground interrogations (UF 4/5/11). The sites fitted on the
ground age out of the time window, and nothing replaces them.

## What our own aircraft tells

Its all-call replies (DF 11) name the interrogator that asked; with its
position (GNSS, or the dead-reckoning estimate during the 16:08–17:08 outage,
see `scripts/dead_reckoning/`), each episode of replies (gaps under 5 min, at
least 20 replies) can be set against the catalogue: the candidate of that
code with the smallest maximum distance over the episode, kept within 450 km.
II 0 is left out (acquisition squitters).

Matches worth trusting:

| UTC | Code | Site | Distance |
|---|---|---|---|
| 13:49 | SI 12 | ParisNord area | 23 km |
| 13:49 | II 1 | Charles de Gaulle area | 4 km |
| 13:49 | II 3 | Paris Sud / Palaiseau | 42 km |
| 14:38–14:51 | SI 54 | Ingolstadt-Manching main (DE) | within 226 km |
| 14:56–15:00 | SI 6 | Bratislava (SK) | within 234 km |
| 15:33–15:35 | II 11 | Ferihegy TAR2 (HU) | within 301 km |
| 15:55–15:56 | II 10 | Bucharest (RO) | 10 km, right below |
| 16:29–17:03 | II 13 | Trabzon (TR) | 23 km at 17:03 |
| 16:58–17:14 | II 8 | Erzurum (TR) | within 277 km |

Others matched at 300–450 km are doubtful (Spangdahlem SI 22, Düsseldorf
II 11, Murtenica SI 6, Koviona II 8, Yalova SI 6, …).

**Most episodes have no candidate within 450 km**: most SI codes over
eastern France, Germany and Austria (SI 10, SI 52, SI 58, SI 21, SI 7, II 3,
II 8 …), Hungary and Romania (SI 53, SI 60, SI 23, II 7 …), the Black Sea and
Turkey (II 14, SI 36, SI 29, SI 23 …), Georgia, Azerbaijan and the Caspian
(SI 41, SI 46, SI 14, II 14, II 11). The catalogue has few sites per code,
and almost none east of Turkey for these codes.

Busiest interrogators since 16:00 (DF 11 replies per 10 min, without II 0):

| UTC | Where | Codes |
|---|---|---|
| 16:00 | Bulgarian coast | SI 6, SI 18, II 7, SI 35 |
| 16:10–16:20 | Black Sea (no GNSS) | SI 6, SI 2, II 2, II 14 |
| 16:30–16:40 | Black Sea, north of Turkey | II 14, II 13, SI 23, SI 29, SI 36, II 3 |
| 16:50 | north-east Turkey | SI 36, SI 41 |
| 17:00 | Trabzon | II 13, II 8, SI 41 |
| 17:10–17:20 | Georgia | SI 41, II 10, SI 46, SI 14 |
| 17:30–18:00 | Azerbaijan, Caspian | SI 46, II 14, SI 41, SI 14, II 11, II 8 |

## What could be done in Travel

1. **One aircraft is enough when it is ours.** For the user's own aircraft,
   accept the nearest candidate within radar range over the whole episode,
   without the 3-aircraft rule. That brings back Bucharest, Trabzon, Erzurum,
   etc. in cruise. During GNSS outages, use the estimated position.
2. **Locate unknown radars from our own aircraft.** A rotating radar hits us
   once per rotation; as we move, the time of the hit drifts by our change of
   bearing seen from the radar. With the rotation period (known from the
   reply rhythm) and our track, a few minutes give a bearing and a range: an
   estimated site for codes the catalogue does not know. Not tried yet.
3. **Extend the catalogue** east of Turkey (Georgia, Azerbaijan, Caspian,
   Central Asia) for the route to Asia.

## To check on the receivers

- jet1090 at a higher gain (or a window antenna) to hear other aircraft again
  in cruise, which would let the existing fitting work.
- uplink1030: why so few ground interrogations in cruise (antenna, gain, or
  simply the geometry from inside the cabin).
