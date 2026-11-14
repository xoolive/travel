# Datalink in travel

Notes on how travel reads uplink (1030 MHz) and datalink (VDL2, VHF ACARS,
HFDL, Airframes.io) messages, what the formats look like, and what we learned
along the way. Code: `Sources/Travel/Ingest.swift` (parsing),
`Dataset.swift` (merging, timeouts), `PlotPanel.swift` (display).

## How messages attach to aircraft

Everything is keyed by the ICAO 24-bit address, like jet1090. Dropping a
jet1090 recording together with its `_uplink.jsonl` and `_vdl2.jsonl` files
merges them per aircraft.

- An address seen only in uplink is not shown: most of the ~3,000 uplink
  addresses of a flight are parity noise.
- An address seen only in datalink is shown when a datalink message gives
  its position (see below); otherwise it waits for another source.

A line is routed by its keys: `uf` → uplink, `bearer` → datalink,
`mmsi` → ship162, `icao24` → jet1090.

## Uplink (1030 MHz)

Fields used: `timestamp`, `uf`, `icao24` (target), `interrogator`, `bds`,
`kind`, `mid`.

- UF 0 → ACAS, UF 16 → ACAS (`kind: "resolution"` → resolution advisory
  coordination), UF 24 → ELM, other formats → radar with its II/SI code.
- UF 16 broadcasts carry `icao24: "ffffff"` and the sender in `mid`; travel
  reads `mid`.
- Shown as the *Interrogations* chart: one row per interrogator, one tick per
  interrogation, coloured by requested register; the time axis spans the
  uplink data only.

## Datalink layouts

datalink has written three layouts; travel reads all of them.

| Layout | When | Shape |
|---|---|---|
| Old envelope | June 2026 (`analysis/datalink_june15.jsonl`) | `{"event", "aircraft": {icao24}, "receiver": {channel_hz}, "message": {"kind": "avlc", "data": {…, "lcf": "S", "payload": {"kind": "acars", "data": {…}}}}}` |
| Keyed envelope | Nov 2026 recordings (`~/20261112_*_vdl2.jsonl`) | `{"event", "aircraft", "receiver", "message": {"avlc": {…, "lcf": {"S": {"sfunc": …}}, "payload": {"acars": {…}}}}}` |
| Flat (beta) | current build (`~/20260615_AA83895248_LFBO_EHAM_vdl2.jsonl`) | `{"timestamp", "frame", "bearer", "icao24", "registration", "flight_id", "direction", "station", "station_name", "avlc": {"lcf": "S", "sfunc": …}, "acars": {…}, "x25": {…}, "arinc622": {…}, "kinematics": {…}, "metadata": [{channel_hz, signal_dbfs, noise_dbfs, freq_offset_hz, …}]}` |

Airframes.io records, as published on Redis, look like:

```
{"bearer", "icao24", "registration", "aircraft_id", "timestamp",
 "airframes": {"payload": {label, text, frequency, tail, from_hex, to_hex,
                           link_direction, airframe: {icao, tail}, flight: {…}, …},
               "src": {addr_type, icao24}, "dst": {…},
               "app": {"text"|"arinc622"|"squitter"|"atis_request"|…: {…}}},
 "kinematics": {…}, "metadata": [{"format": "airframes.io", …}]}
```

Display:

- Summary from the innermost layer: `ACARS <label>`, `X.25 <packet type>`,
  `XID`, or the AVLC function (`Receive ready`, `Selective reject`…).
- ARINC 622 messages are named from `imi`: ADS → ADS-C, DIS → ADS-C
  disconnect, AT1 → CPDLC, CR1/CC1/DR1 → CPDLC logon/connect/disconnect,
  AB1 → AOC; the `atsu_address` (e.g. `RUHAAYA`) is shown as the station.
- Other Airframes applications are appended (`· Atis Request`).
- The bearer prefixes the summary unless it is `vdl2`, `vhf`/ACARS,
  `decoded` or `unknown` (e.g. `HFDL ACARS H1`).
- With `station_name`, the airport code (first word) replaces the station
  address; the full name is in the tooltip.
- The same frame is often decoded on 2–4 neighbouring 25 kHz channels at
  once; travel merges identical messages within 1 s and shows `136.850 +2`.

## Positions from datalink

`kinematics.derived_from` says where a position comes from (see
`crates/acars/src/decode/compact.rs` in datalink):

| `derived_from` | Source | Used |
|---|---|---|
| `adsc_basic` | ADS-C basic report (position, altitude) | yes |
| `adsc_earth`, `adsc_air` | ADS-C track / heading only | track |
| `cpdlc`, `cpdlc_position_report` | CPDLC | yes |
| `label32`, AOC formats | ACARS position messages | yes |
| `vdl2_xid_aircraft_location` | VDL2 XID | yes |
| `hfdl_performance`, `hfdl_frequency` | HFDL | yes |
| `airframes_flight` | Airframes.io flight tracking, ~0.1° | position and track, not altitude |
| `squitter` | **ground station** position | no |
| `oooi_qf`, `oooi_qq` | no position | — |

Airframes flight-tracking altitudes can be ten times too large (255,000 ft
seen), hence ignored.

Datalink positions are kept apart from received ADS-B positions
(`Series.reported`) and only used for aircraft without positions of their
own, so that coarse points do not make jet1090 tracks zigzag.

### ADS-C

The report lives in `arinc622.payload.adsc` (flat layout) or
`airframes.app.arinc622.payload.adsc` (Airframes on Redis), as a list of
single-key tags (`AdscTag` in `crates/acars/src/decode/payload/arinc622/adsc.rs`):

- `basic_report` and the same layout in `emergency_basic_report`,
  `lateral_deviation_change_event`, `vertical_rate_change_event`,
  `altitude_range_event`, `waypoint_change_event`: `latitude`, `longitude`,
  `altitude_ft`, `timestamp_seconds_past_hour`.
- `earth_reference_data`: `true_track_degrees`, `ground_speed_kt`,
  `vertical_speed_ft_per_min`.
- `air_reference_data`: `true_heading_degrees`, `mach`.
- `meteo_data`: wind and temperature (not used yet).
- `flight_id`: `callsign`.
- `predicted_route`, `intermediate_projection`, `fixed_projection`: not used yet.

travel reads these tags directly, because `kinematics` is not enough:

- It only keeps the basic report (no track or speed).
- On Airframes records datalink merges `raw.merge(app)`
  (`crates/datalink/src/airframes.rs`), so the Airframes flight position
  wins over the ADS-C report and is labelled `airframes_flight`.

When an ADS-C position is present, `kinematics` positions are ignored. The
report time is rebuilt from the reception time and
`timestamp_seconds_past_hour`.

In Airframes captures, ADS-C contract requests are label A6 (uplink) and
reports label B6 (downlink). Messages from Airframes may carry a prefix
before the envelope (`L91ASQ0421/SKYSWSQ.ADS.…`); datalink strips it.

### Timeouts

ADS-B aircraft disappear 60 s after their last message. Aircraft located
only by datalink stay 30 minutes (`Dataset.reportTimeout`), with their
altitude and speed, and move along the line between two reports less than
2 h apart.

## Redis

datalink publishes one topic per application (`redis_topic_for_record` in
`crates/datalink/src/util.rs`): `datalink-acars`, `datalink-x25`,
`datalink-cpdlc`, `datalink-adsc`, `datalink-sq`, `datalink-xid`,
`datalink-vdl2`, `datalink-hfdl`, `datalink-unknown`.

travel subscribes to channel names containing `*`, `?` or `[` with
`PSUBSCRIBE`; new Redis sources default to `jet1090 ship162 datalink-*`.
Sources saved before keep their channels.

`PUBSUB CHANNELS` only lists channels with subscribers, so listening is the
way to see what is published (`uvx iredis`, or a raw socket).

## Open points in datalink

- The `Bearer` enum maps `acars`/`vhf`, `vdl`/`vdl2`, `hf`/`hfdl`;
  satellite ACARS (`aero-acars`), which carries most oceanic ADS-C, becomes
  `unknown`.
- `kinematics` on Airframes records prefers Airframes tracking over the
  decoded ADS-C/CPDLC position; the reverse would be more precise.
- One LFPG–EHAM message was attributed to an EGLL station: worth checking
  in `VDL2_Ground_Stations.txt`.
- The ADS-C layout on Redis was checked against the Rust types and the
  `decode arinc622` output, not yet against a live `datalink-adsc` message.

## Layout suggestions (13 Nov 2026)

Compared with jet1090 (`timestamp`, `frame`, `df`, `icao24`, decoded fields
at the top, `metadata: [{rssi, serial, name}]`) and uplink (`timestamp`,
`frame`, `uf`, `icao24`, `rssi`, `confidence`), we suggested for datalink:

1. Same top level as jet1090: `timestamp`, `frame`, `icao24` (always the
   aircraft), plus `registration`, `flight_id`. *Done in the flat layout.*
2. Explicit `station`, `station_name`, `direction`. *Done.*
3. Internally tagged variants (`{"lcf": "S", "sfunc": …}`) rather than the
   variant name as key. *Done.*
4. One object per layer side by side (`avlc`, `x25`, `acars`, application).
   *Done.*
5. Merge copies from neighbouring channels into one line with several
   `metadata` entries. *Not done (no deduplication, by choice).*
6. A schema version. *Not done, by choice.*

For uplink: move `rssi` and `confidence` into `metadata`, and put the ACAS
sender in `icao24` instead of `ffffff` + `mid` (planned in datalink's
`analysis/BETA_FLAT_OUTPUT_PLAN.md`).
