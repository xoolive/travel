# VDL2 received on board: AF162, 15 November 2026

Receiver in the cabin of AF162 (AFR162, F-HUVR, `39d2b1`), Paris CDG → Tokyo
Haneda. Decoder: `datalink vdl2 rtlsdr://` (centre 136.5 MHz, channels
136.675, 136.725, 136.775, 136.825, 136.850, 136.875, 136.900, 136.975 MHz),
output `~/output_vdl2.jsonl`, also on Redis (`datalink-*`).

## What is received

172 frames over 5 h 15 (12:48–18:02 UTC), about 33 an hour.

- **All are downlinks from our own aircraft.** Nothing from ground stations,
  nothing from other aircraft, the whole flight.
- **All checksums are good** (`fcs_ok`): decoding is clean.
- Signal −21 to −0.1 dBFS, median −10 dBFS, noise about −38 dBFS: our own
  transmitter, close to full scale. Ground stations are much weaker: the
  cabin, the gain set for a nearby transmitter, or both, keep them out.

| Kind | Frames | What it is |
|---|---|---|
| Receive Ready (S) | 133 | link keepalives, identical while the counter does not move |
| X.25 / ATN (I) | 30 | compressed CLNP + COTP **acknowledgements** of a CPDLC session |
| Selective Reject (S) | 5 | requests to resend lost frames |
| ACARS | 2 | label `_d`, empty text (flight id AF0162, registration) |
| Unnumbered (U) | 2 | DM (Disconnected Mode) to station `2a0a77` |

The CPDLC session (ATN, transport connection references 15279 → 53726 →
48418) stays up across ground station changes and is active until Bulgaria
(last acknowledgement around 16:05). Only acknowledgements are seen: the CPDLC
messages themselves come down from the ground (uplinks), which we do not
receive.

## Ground stations along the route

| UTC | Station | Channel (MHz) |
|---|---|---|
| 12:48–13:59 | LFPG Paris CDG (on the ground) | 136.875 |
| 14:00 | LFJL Metz | 136.900 |
| 14:25 | LFSD Dijon | 136.900 |
| 14:30 | EDMO Oberpfaffenhofen | 136.900 |
| 14:55 | LHPR Győr | 136.900 |
| 15:30 | LHPP Pécs | 136.900 |
| 15:35 | LYBE Belgrade | 136.775 |
| 15:45 | LRCK Constanța | 136.975 |
| 15:55 | LROP Bucharest | 136.975 |
| 16:00 | LBBG Burgas | 136.775 |
| 16:15 | LTFJ Istanbul Sabiha Gökçen | 136.975 |
| 16:45 | LTAC Ankara | 136.975 |
| 17:05 | LTFH Samsun | 136.975 |
| 17:10 | LTCI Van, LTCG Trabzon | 136.975 |
| 17:35– | `2a0a77`, then `23e497`: unknown to the decoder (no name, no position) | 136.975 |

- Stations are chosen by link quality, not along the route (Dijon after Metz).
- Since 16:15 everything is on 136.975 MHz.
- Long silences over the Black Sea (16:25–17:05): far from the coasts.
- At 17:41–17:42 the aircraft sends DM to `2a0a77` (it refuses or ends that
  link) and stays with `23e497`. These addresses are not in the decoder's
  station table: probably the Caucasus or the Caspian.
- Station positions, when present, are rounded to 0.1° (about ±5 km).
- Timestamps are from the system clock (`time_source: system`), not GPS.

## Known problems

- **Copies on neighbouring channels**: the same frame decoded at the same
  instant on 136.850 / 136.900 at about −20 dBFS, beside the real 136.875 at
  about −1 dBFS (3 cases, at 12:48:17 and 13:19:21). They should be merged by
  keeping the strongest copy within a few milliseconds (Travel already merges
  same-frame copies, `Dataset.swift`). Not to be confused with genuine
  repeats minutes apart (Receive Ready frames with the same counter).
- **Unknown ground stations** east of Turkey: the station table needs entries
  for `2a0a77`, `23e497`.

## To try

- Lower the gain (or an antenna by the window) to receive uplinks: CPDLC
  content, ground station positions, other aircraft.
