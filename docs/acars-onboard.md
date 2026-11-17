# VHF ACARS received on board: AF162, 15 November 2026

Follows `vdl2-onboard.md`. VDL2 went silent at 18:02 UTC (last frames to
the unknown station `23e497` on 136.975 MHz), over Kazakhstan. At 20:15 UTC
the RTL-SDR was switched to classic VHF ACARS:

```sh
datalink vhf rtlsdr:// --center-freq 131.6M --sample-rate 1.05M \
  --channel 131.45M 131.55M 131.725M \
  --output ~/output_acars.jsonl --redis-url redis://localhost:6379
```

## Why these frequencies

Below, "documented" means the datalink repository says so, and "general
knowledge" means it does not and the point is still to confirm.

- The decoder's ground station table (`VDL2_Ground_Stations.txt`, acars-vdl2
  community) lists about 65 Chinese and 38 Japanese stations, but none with a
  frequency, and none in Kazakhstan or Central Asia.
- The VHF ACARS frequencies come from the datalink docs (`docs/getting-started.md`):
  - 131.450 MHz: documented for Japan; China is general knowledge;
  - 131.550 MHz: SITA worldwide primary;
  - 131.725 MHz: SITA Europe.
- The three fit in 275 kHz, about 5 MHz away from 136.975 MHz, so one
  RTL-SDR cannot cover both ACARS and VDL2.

## What was received (20:15–21:35 UTC)

11 messages, **all downlinks from our own aircraft** (F-HUVR, flight id
AF0162). As with VDL2, there are no ground uplinks and no other aircraft.
The signal is at 0 dBFS: our own transmitter saturates the dongle.

| UTC | MHz | Label | Text | Reading |
|---|---|---|---|---|
| 20:23:12 | 131.725 | 5U | `1ZLDH` | probably a weather request for ZLDH, Dunhuang (Gansu, China), plausibly an en-route alternate |
| 20:23:17 | 131.725 | _d | (empty) | general response / keepalive |
| 20:29:47, 20:29:59, 20:30:08 | 131.725 | 2F | `2029+4355+7910/37385` | position report, sent 3 times |
| 20:43:32, 20:43:40, 20:43:47 | 131.725 | Q0 | (empty) | link test, 3 attempts |
| 20:44:07 | **131.450** | Q0 | (empty) | link test on the other frequency |
| 20:44:13 | 131.450 | SA | `0EV204412V/` | media advisory: link **E**stablished, **V**HF ACARS, 20:44:12 |
| 20:44:45 | 131.450 | 5V | (empty) | airline-defined, unknown |

Nothing more until 21:39 UTC, then:

| UTC | MHz | Label | Text | Reading |
|---|---|---|---|---|
| 21:39:06 | 131.450 | Q0 | (empty) | link test |
| 21:39:12 | 131.450 | SA | `0EV213911VSH/` | VHF ACARS **E**stablished at 21:39:11; links available: **V**HF, **S**atcom, **H**F |
| 21:39:46 | 131.450 | SA | `0LH213945VS/` | **L**ost **H**F at 21:39:45; still available: VHF, Satcom |

So the aircraft also has HF datalink (HFDL) and satcom. At 20:44 only VHF
was listed; an hour later HF and satcom were listed too.

## 22:12–22:57 UTC: weather reports (checked 23:29)

27 more downlinks, all on 131.450 MHz, then silence again after 22:57:31.

- **Routine traffic:**
  - Q0 link tests every 4–6 minutes, each followed by a 5V;
  - another HF link up and down: `0EV224939VSH/` (VHF established, V/S/H
    available), then `0LH225229VS/` (HF lost);
  - `_d` messages carrying acknowledgements of uplink blocks B, C and J
    (J four times, 10 s apart). So the aircraft does receive uplinks; we
    just cannot hear them.
- **Missed messages:** the message numbers run S58 → S88, with gaps
  (S60–S63, S69, S74, S77–S78). Either we missed about a quarter of the
  downlinks, or they went over satcom/HF.

### Label MA (MIAM): automatic weather reports

Two reports, 20 minutes apart. A compressed MIAM header, then readable CSV:

```
22:30:41  |A350,000093,1,1,TB000000/REP081,01,01;A06/NX,LFPG RJTT/0,7,+150625,+366898,1290627,3914,-560,254,050,X,3,2,0,0,51,48,50,48,41/
22:50:42  |A350,000094,1,1,TB000000/REP081,01,01;A06/NX,LFPG RJTT/0,7,+146887,+380066,1291827,3914,-559,261,056,X,3,2,0,0,51,48,55,71,88/
```

Decoded, and checked against our ADS-B:

| Field | Report 1 | Report 2 | Reading | Check |
|---|---|---|---|---|
| `000093`, `000094` | | | report counter | consecutive |
| `LFPG RJTT` | | | origin, destination | ✓ |
| `+150625` / `+146887` | 41.8403° N | 40.8019° N | latitude in arc-seconds (÷ 3600) | ADS-B 41.8414 / 40.8034 |
| `+366898` / `+380066` | 101.9161° E | 105.5739° E | longitude in arc-seconds | ADS-B 101.9125 / 105.5699: both within about 0.2 NM |
| `1290627` / `1291827` | 22:30:27 | 22:50:27 | seconds since the start of the month (UTC) | 14 d 22:30:27; 1,200 s apart |
| `3914` | 39,140 ft | 39,140 ft | altitude, tens of feet | baro 39,100 ft |
| `-560` / `-559` | −56.0 °C | −55.9 °C | static air temperature, tenths of °C | ISA at FL391 is −56.5 °C |
| `254,050` / `261,056` | 254° / 50 kt | 261° / 56 kt | wind direction / speed | ADS-B ground minus air vector: 260° / 48 kt and 264° / 54 kt |
| `TB000000` | | | turbulence flags (?), all zero | smooth ride |
| `X,3,2,0,0` | | | unknown | |
| last five | `51,48,50,48,41` | `51,48,55,71,88` | unknown: perhaps turbulence (EDR) or humidity samples | |

These look like AMDAR-style meteorological reports: position, time,
altitude, temperature and wind, every 20 minutes. The wind agrees with our
own estimate (`scripts/dead_reckoning/`, the ground vector minus the air
vector) within 6° and 2 kt.

### Position report (label 2F)

- `2029` is the time (UTC). `+4355+7910` is **43.55° N 79.10° E**, decimal
  degrees to two places: it is not degrees and minutes.
- ADS-B gives 43.555° N 79.029° E at 20:29:20. At 505 kt the aircraft is at
  about 79.11° E at 20:29:47, when the report was sent. The two agree within
  about 1 NM, near the Kazakhstan–China border (Khorgos).
- `37385` is not the altitude:
  - barometric altitude was 37,000 ft;
  - GNSS altitude was about 36,200 ft (ADS-B GNSS minus baro, −700 to
    −800 ft);
  - fuel on board in kg is a guess, to check on other reports.

### Handover from 131.725 to 131.450

- The position report was repeated 3 times at about 10 s intervals, then
  the link test 3 times. That suggests the 131.725 ground station did not
  acknowledge them (we cannot hear the ground to confirm).
- Seconds after switching to 131.450 MHz, the aircraft declared the link
  established (SA, media `V`).
- So the aircraft uses classic ACARS, not VDL2, over this region. In the
  media advisory, `V` stands for VHF ACARS (general knowledge, not checked).

## Listening plan for the rest of the flight

- **Over China: stay on VHF ACARS, 131.450 MHz**, which the aircraft
  selected. 131.550 and 131.725 cost nothing to keep.
- **Before Korea and Japan: switch back to VDL2.** Use 136.975 MHz only, not
  the 8 European channels: this also lowers the decoder's CPU use (about
  99 % of a core with 8 channels).

  ```sh
  # centre off the channel, away from the RTL-SDR DC spike
  datalink vdl2 rtlsdr:// --center-freq 136.8M --channel 136.975M \
    --output ~/output_vdl2.jsonl --redis-url redis://localhost:6379
  ```

  Expected timing:
  - the AF162 profile crosses Tianjin at about 23:56 UTC;
  - Korea and the Sea of Japan follow, then the descent into Haneda.
- **If ACARS stays silent for a long time over China**, the aircraft may be
  on satellite. Try VDL2 136.975 for 15 minutes before concluding.
- **Lower the gain**: our own transmitter at 0 dBFS saturates the dongle.
  Ground uplinks would need headroom, and an antenna near a window.

## Open questions

- What `37385` is in the 2F report.
- What labels 5U and 5V carry for Air France (airline-defined).
- Whether 131.725 was really unanswered, or just weaker on the ground side.
