# Point merge on arrival at Haneda (AF162, 16 November 2026)

AF162 (F-HUVR, 39d2b1) flew Haneda's point merge on the OSHIMA 1A arrival
to runway 34L/34R. The sequencing leg is at 18.7 NM from the merge point
WEDGE, and the aircraft was turned direct to WEDGE from about the middle of
the leg.

```sh
python wedge.py ~/20261115_AA89665103_LFPG_RJTT.jsonl 39d2b1 02:05:00 02:23:00
```

## The procedure in the AIP

Haneda has run point merge since July 2019
([EUROCONTROL news](https://www.eurocontrol.int/news/tokyo-haneda-one-worlds-busiest-airports-set-implement-point-merge-eurocontrols-innovative)).
The AIP never calls it that: it is built into the RNAV STARs to runway
34L/34R. The sequencing leg is drawn as straight TF legs between points on a
circle around the merge point.

OSHIMA 1A, AIP Japan RJTT AD2.24-STAR-11/12 (EFF 31 OCT 2024):

> From XAC, to ANZAC at 13000FT, to TT450, to TT451, to TT452, to TT453,
> to WANDA at 13000FT, to WEDGE at 8000FT, to ARLON.

| Fix | NM to WEDGE | Role |
|---|---|---|
| XAC (Oshima VORTAC) | 38.3 | start of the STAR |
| ANZAC | 23.2 | entry, 13,000 ft |
| TT450 | 18.74 | sequencing leg |
| TT451 | 18.77 | sequencing leg |
| TT452 | 18.76 | sequencing leg |
| TT453 | 18.73 | sequencing leg |
| WANDA | 18.69 | end of the leg, 13,000 ft |
| WEDGE | 0 | merge point, 8,000 ft |
| ARLON | 6.4 N of WEDGE | towards the final for 34L/34R |

Other arrivals have the same pattern, not checked here:
- AROSA via TT457–TT459 to WALTZ;
- the TT250–TT257 legs (XAC, AKSEL and AROSA arrivals);
- GODIN via TT680/TT681.

## What we flew

From our own ADS-B positions (`wedge.py`):

| UTC | NM to WEDGE | Altitude (ft) | What |
|---|---|---|---|
| 02:07:11 | 40.7 | 16,000 | passing Oshima (XAC) 2.6 NM off, then left to ANZAC |
| 02:10–02:12 | 30 → 19 | 13,000 | course 027°, ANZAC then TT450 |
| 02:12:43 | 18.4 | 13,000 | on the sequencing leg, course 097–109° |
| 02:14:05 | 18.7 | 13,000 | past TT451; descent starts at 02:14:25 |
| 02:15:28 | 18.7 | 11,800 | at TT452, course 079° |
| 02:16:30 | 18.2 | 10,750 | turning left off the leg, before TT453 |
| 02:17:51 | 14.0 | 9,300 | course 330°, WEDGE bearing 313° |
| 02:18:12–02:19:13 | 12.6 → 8.8 | 9,000 → 8,300 | course 325–315° (WEDGE at 309–312°) |
| 02:21:55 | 1.3 | 6,200 | passing WEDGE |
| 02:22–02:23 | | 6,000 | course 300° towards Haneda |

- On the leg (02:12:43–02:16:10) the distance stays at 18.2–18.7 NM: the
  aircraft follows the circle, not a turn of its own.
- After leaving the leg, the distance to WEDGE falls steadily from 18 to
  1.3 NM: direct to the merge point.
- Taken off at about the middle of the leg (after TT452, before TT453),
  that is little stretching. This is a guess: the cabin receiver decoded no
  other arrival, so the sequence is not visible.
- The descent started on the leg (02:14:25), below the published 13,000 ft,
  and WEDGE was passed at 6,200 ft instead of 8,000 ft: ATC clearances, not
  the published profile.

## How it was first missed

A circle fitted to the 13,000 ft level segment (02:10:22–02:14:28) gave a
9 NM radius centred near 34.72°N 139.83°E, and looked like a wide turn. That
fit took in the run from ANZAC to TT450, before the leg. Measuring the
distance to the merge point the AIP names shows the arc directly.

## Sources and caveats

- AIP Japan from a third-party mirror
  ([RJTT charts](https://nagodede.github.io/aip/japan/documents/RJTT_chart.pdf),
  [RJTT AD 2](https://nagodede.github.io/aip/japan/documents/RJTT_full.pdf)).
  The official AIS Japan site needs registration. Pages are dated 2024–2025:
  check against the current AIRAC.
- MLIT,
  [Important points of ATC Operation at Tokyo International Airport 2026S](https://ops.group/blog/wp-content/uploads/2026/08/Important-points-of-ATC-Operation-at-Tokyo-International-Airport_2026S-1.pdf).
- Field 15 of the flight plan ends with the arrival `XAC1A`, OSHIMA 1A.
