# Next steps

## Flight plan routes from AIRAC data (field 15)

Done: `Airac.swift` reads the EUROCONTROL AIXM baseline of the latest
`~/Documents/data/airac/AIRAC_*` folder (`DesignatedPoint`, `Navaid`,
`AirportHeliport`, `Route`, `RouteSegment`, SIDs/STARs and their legs), the
way thrust does, and keeps an index in `~/Library/Caches/travel/` (built once
per AIRAC, about 30 s). `FlightPlan.waypoints()` resolves field 15: SID,
named points (nearest the previous one), airways along their segments,
coordinates, STAR. A SID/STAR whose revision differs from the AIRAC data
(LANVI7A against LANVI6A) falls back to the same point and letter.
`Travel --plan FILE` prints the resolved route.

Left:

- Outside the EUROCONTROL area, no SIDs/STARs (RJTT arrivals) and only the
  points and airways the baseline carries: FAA NASR or DDR data as in thrust's
  `field15_multisource.rs` would fill that in.
- Field 15 speed/level changes after points (`POINT/N0480F390`) are dropped.

## Airways outside EUROCONTROL: fallback on traffic's `earth_awy.dat`

Seen on board AF162 (15 November 2026): field 15 reads `… POSOT B215 FKG
W188 LIKMI W270 DKO W69 DUDIL …`. The AIXM baseline has none of the Chinese
airways, so Travel draws FKG → LIKMI as a straight line. The aircraft flew
W188 point by point, and Travel showed it 28 NM north of the route. It passed
these points within 3–4 NM:

| Point | UTC |
|---|---|
| WUR (Urumqi) | 21:13 |
| FKG | 21:16 |
| ADPET | 21:25 |
| ESGIV | 21:32 |
| DAKPA | 21:34 |
| RIMDU | 21:42 |
| BATUS | about 21:53 |

The same gap affects W270, W69, B339, W34, W100, W201, A326, G597, Y644 and
Y71, all the way to Haneda.

### Source

`~/Documents/code/traffic/src/traffic/data/navdata/earth_awy.dat`
(3.7 MB, about 9,700 designators, about 1,060 of them in East Asia). One line
per point: `DESIGNATOR SEQ NAME LAT LON`. It has every airway of the AF162
route east of Europe. W188, Chinese section:

```
DUKOM 44.17 87.98 · ADPET 44.42 89.69 · DAKPA 44.03 91.42 · PORUP 43.84 92.17
BATUS 43.13 95.09 · LIKMI 42.39 95.77 · GOVSA 41.87 96.24
```

### To do

1. **Load it only as a fallback.** For an airway whose entry and exit points
   are not joined by AIXM `RouteSegment`s, look it up in `earth_awy.dat`.
   - Path: a setting, defaulting to traffic's copy, or a copy in
     `~/Documents/data/`.
   - Index it next to the AIRAC index in `~/Library/Caches/travel/`.
2. **Split each designator into sections.** One designator mixes airways of
   several countries in one numbering: W188 has an Australian section, a
   Russian one (BALOM…INDIK) and the Chinese one. Cut wherever consecutive
   points are more than about 300 NM apart. Keep the section containing
   both route points, and take the points between them in either direction.
3. **Match by position as well as by name.** The airway calls the fix DUKOM
   where the flight plan names the navaid FKG, at the same coordinates. A
   route point matches an airway point with the same name, or one within
   about 1 NM.
4. **Stay with the straight line** when the airway is missing or does not
   reach both points, as today.
5. **Mark the source.** Points coming from this file are older data. Show
   them as such in `Travel --plan` and keep them out of anything treated as
   authoritative.

### Caveats

- **Age.** The file was last changed in traffic's `317f4fe` (2023-08-22).
  ESGIV and RIMDU, overflown on W188, are not in it, though PORUP is: it
  lags the real airway. Good enough to draw the route within a few NM, not
  to name every point.
- **Provenance and licence unknown.** There is no header. It looks like
  X-Plane / DAFIF-derived data (X-Plane's default data is GPL). Check where
  traffic got it before bundling or redistributing it with Travel; reading
  it from the user's traffic install avoids redistribution.
- **Other sources.**
  - The official CAAC eAIP was not found online; old AIP China ENR 3 PDFs
    (2015, 2019) are on a third-party mirror.
  - Current data is commercial: the ICAO airways dataset (USD 5,000),
    Navigraph and Jeppesen.
  - X-Plane's current `earth_awy.dat` (format XP-AWY1101) ships with the
    simulator; no standalone download was found.
- **SIDs/STARs** outside EUROCONTROL: typed in from the AIP into
  `~/Documents/data/travel/procedures.txt` (`Procedures.swift`, or
  `TRAVEL_PROCEDURES`), each block with its source. It has the RJTT
  OSHIMA arrivals XAC1A, XAC1K and XAC2C (AIP Japan AD2.24-STAR-11 to -14,
  EFF 31 OCT 2024, from a public mirror; the official eAIP needs a login).
  AF162 flew XAC1A as far as TT452, was cut short of WANDA, then flew the
  XAC1K ending (UMUKI 0.1 NM, KAIHO 0.2 NM).

## Navigation data: several sources, one interface

Today the route resolver has three hand-wired paths:
- the AIXM baseline (`Airac`);
- X-Plane airways (`XPlaneAirways`);
- a hand-typed procedures file (`Procedures`, the RJTT XAC STARs).

Each new region would add another special case. Replace them with one layer.

- **One model.** Points, navaids, airways (segments, with direction when
  known), SIDs/STARs/approaches as ordered legs with their constraints
  (altitude, speed, path terminator). Every item carries its source and
  its validity (AIRAC cycle or effective date).
- **Sources as adapters**, each turning its format into that model:
  - EUROCONTROL AIXM baseline (as now);
  - ARINC 424, which covers most of the rest with one parser: FAA CIFP
    (public, US procedures), X-Plane's `CIFP/*.dat` and `earth_*.dat`
    from a simulator install, a Navigraph or Jeppesen file the user
    provides;
  - national eAIPs: AIP Japan (AIS Japan, HTML after a free login) and
    others in the EUROCONTROL eAIP format, with tables that can be parsed
    (STAR legs, waypoint coordinates), cached per effective date;
  - local corrections and additions (BOTKI on W270, inferred from a track)
    in the same model, marked as such.
- **Precedence by region and date**: the most recent official source
  covering the area first, then the others; an older or unofficial source
  only fills gaps. The resolver asks the layer, not each source.
- **Provenance in the interface**: `Travel --plan` and the plan card say
  which source gave each point and of which cycle. The map draws
  non-official points differently.
- Nothing redistributed: sources are read from where the user keeps them
  (`~/Documents/data/…`, a simulator, traffic), indexed in
  `~/Library/Caches/travel/`.

## Runway thresholds: drop the RJTT correction once OurAirports has it

`Resources/runways.csv` comes from OurAirports, read from traffic's cache
(`~/Library/Caches/traffic/runways_ourairports.parquet`). At RJTT that copy
was wrong:

- 34R gave the displaced threshold, not the runway end (367 m off);
- 34L, 05 and 16L were 29–43 m off;
- 05's heading read 57°.

The bearings of 16L/34R and 16R/34L were off by 1.0° and 0.5°, enough to
delay runway alignment by a nautical mile (AF162 on 34L, 16 November 2026).

- **For now:** `scripts/make-runways.py` replaces the RJTT ends with the AIP
  values (`CORRECTIONS`, AIP Japan RJTT AD 2.12, EFF 28 NOV 2024), and the
  CSV has them.
- **Upstream:** the eight RJTT ends were corrected on OurAirports on
  18 November 2026 and checked against the AIP:
  - positions, headings and elevations;
  - displaced thresholds 16L 1280 ft, 34R 1180 ft, 16R 1577 ft.
- **Later, to do:**
  - Refresh traffic's cache (or OurAirports' `runways.csv` export), and check
    that its RJTT rows match the AIP.
  - Then remove the RJTT entries from `CORRECTIONS`, regenerate, and check
    that `git diff Resources/runways.csv` shows no RJTT change.
- Other airports may have the same kind of error: compare with their AIP when
  an alignment looks late or misses a runway.

## Decoders for local receivers

Travel recognises SDR receivers plugged into the Mac (`UsbDevices.swift`,
the device tree), but nothing decodes them yet. `AppState.start` has the
comment "Receivers are not connected to a decoder yet". The decoders already
exist in Rust: jet1090 (rs1090, desperado for the radio), ship162 (AIS),
uplink1030, datalink (VDL2).

### Chosen: run them as child processes

- Find the binaries:
  - a path setting;
  - else `PATH` and `~/.cargo/bin`;
  - later, binaries bundled in `Travel.app/Contents/Helpers`.
- Start one per live receiver source, on the device chosen in the tree.
  - Check how each decoder selects a device by serial number. RTL-SDR
    dongles often share one: `LiveSource.match` already deals with that.
- Read JSON lines from their output: the same format as recordings and
  Redis, so `Ingest` is unchanged. Optionally also publish to Redis, so that
  scripts (dead reckoning) see the data.
- Stop them with the source. Report a crash or exit as the source's status
  (`LiveStatus.failed`). Mark the receiver as taken in the device tree
  (`takenBy`).
- No Rust in the Swift build. A crash stays in the child process.

### Not chosen, for now: linking Rust into Travel

Rust compiles to a static library with a C interface:

- `extern "C"` and a header from `cbindgen`;
- or UniFFI / `cargo-swift` for generated Swift types.

It is worth it only for:

- decoding raw recordings (Beast or hex) when they are loaded;
- one self-contained app with nothing else to install;
- controlling the radio (gain, frequency) from the interface.

The costs:

- a Rust toolchain in the build;
- universal libraries for both Apple Silicon and Intel;
- callbacks from Rust threads under Swift 6 concurrency.

A possible middle way: only the rs1090 decoder, one C function from raw
bytes to a JSON string.

## Ambiguous VDL2 ground stations (shared addresses)

Seen on board AF162 (16 November 2026): over the Yellow Sea, our aircraft
sent two frames to `1054ba` (00:26:36 and 00:30:50 UTC, 136.975 MHz). The
decoder named no station:

```
"station":"1054ba", "station_ambiguous":true,
"station_full_name":"KBWI Baltimore Washington / RKSI Seoul Incheon S.Korea"
```

- The community table (`VDL2_Ground_Stations.txt`, bundled in datalink as
  `crates/datalink/data/vdl2_stations.json`) gives one address to two sites:
  `1054BA [KBWI Baltimore Washington 39°12'N 076°42'W / RKSI Seoul Incheon
  S.Korea 37°30'N 126°24'E]`.
- datalink's `parse_station` (`crates/datalink/src/stations.rs`) treats any
  label with ` / ` as ambiguous. It deliberately drops the short name and
  the coordinates, so as not to guess a location.
- The answer is obvious from our position: 284–335 km from Incheon, about
  11,000 km from Baltimore.
- A second one at 00:41:29: `1050fa`, `KLAS Las Vegas Harry Reid / RKPC
  Jeju S.Korea`, with no coordinates for either half. Jeju is 429 km away,
  Las Vegas 9,785 km. Jeju was chosen although Incheon was only 134 km away:
  stations are picked by link quality, not distance. A 500 km range limit
  still holds; the coordinates of Jeju have to come from an airport table.
- 29 table entries are like this, nearly all a Korean station sharing an
  address with a US one (`1054ca` San Francisco / Yeosu, `1054ea`
  Cleveland / Jeju, …).
- The decoder has the candidate sites but not the aircraft position; Travel
  knows the position but not the candidates.

### 1. datalink: emit the candidates

- Split ambiguous labels on ` / ` into sites, each with its ICAO code, name
  and coordinates when the label has them (`Station.candidates`).
- Write them in the JSON output as `station_candidates`:
  `[{"name": "RKSI", "full_name": "Seoul Incheon S.Korea", "latitude": 37.5, "longitude": 126.4}, …]`.
  Keep `station_ambiguous: true` and leave `station_name` empty: the decoder
  still does not guess.
- Some halves have no coordinates (`RKJJ Gwangju`): fill them from an
  airport table by ICAO code, or leave them out.
- Test on `1054ba`.
- Later, optionally: with a known receiver position (a `--location`
  option), the decoder could pick the candidate itself. That works for a
  ground receiver, not on board.

### 2. Travel: pick the candidate nearest the aircraft

- In `Ingest.datalink`, keep the candidates with the message.
- In the dataset, where the aircraft's position at the frame's time is
  known, take the nearest candidate within VDL2 range (about 500 km at
  cruise, the radio horizon). Otherwise leave the station unknown.
- Use it as the station: name, position, the dashed link on the track, and
  a ground station mark on the map.

### Not chosen

Travel reading `VDL2_Ground_Stations.txt` itself and resolving ambiguous
addresses alone would be quicker. But it would duplicate the station logic
of datalink.
