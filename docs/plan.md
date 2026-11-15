# Next steps

## Flight plan routes from AIRAC data (field 15)

Dropped `.flight.json` plans show field 15 as text in the aircraft panel and
draw a dashed route on the map, but only through the coordinates written in
the route and the two airports: named points are not placed yet. A first
version used a navaid table generated from the traffic cache
(`navaids.csv`); it was removed in favour of the AIRAC data.

Use the EUROCONTROL AIXM baseline in `~/Documents/data/airac/AIRAC_2606/`
(zip per feature type: `DesignatedPoint`, `Navaid`, `AirportHeliport`,
`Route`, `RouteSegment`, `StandardInstrumentDeparture`,
`StandardInstrumentArrival`, `DepartureLeg`, `ArrivalLeg`, …), configured as
a folder rather than bundled, and parse it as already done in:

- thrust (Rust): `crates/thrust/src/data/field15.rs` (field 15 parser:
  points, connectors, speed/level changes), `crates/thrust/src/data/airac.rs`,
  `crates/thrust/src/data/eurocontrol/aixm/` (`designated_point.rs`,
  `navaid.rs`, `route.rs`, `route_segment.rs`,
  `standard_instrument_departure.rs`, `standard_instrument_arrival.rs`,
  `arrival_leg.rs`), and the example
  `crates/thrust/examples/field15_multisource.rs`, which resolves a field 15
  against AIXM, DDR and FAA NASR data;
- traffic (Python): `src/traffic/data/eurocontrol/aixm/navpoints.py`,
  `airspaces.py`.

Steps:

1. Decide how Travel gets at it: a small export from thrust (e.g. its CLI or
   an example writing the resolved route as JSON), or parsing the AIXM zips
   in Swift for the few features needed.
2. Resolve each named point against `DesignatedPoint` and `Navaid` (names
   repeat: nearest the previous point), expand airways (`UT182`) through
   `RouteSegment` between their entry and exit, and SIDs/STARs
   (`FISTO7B`, `KEPER9W`) through their legs.
3. Draw the resolved route; keep the text of field 15 in the panel.
