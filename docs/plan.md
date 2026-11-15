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
