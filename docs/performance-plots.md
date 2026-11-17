# Plot panel under live data: performance analysis (to do)

Observed on board AF162, 15 November 2026, 21:08 UTC, Travel running since
about 14:35 UTC with live Redis feeds (jet1090, uplink1030, datalink-*), the
plot panel open on our own aircraft (`39d2b1`).

## Symptoms

- Travel at about 70 % of one core, physical footprint 1.1 GB (peak 2.1 GB).
- The interface lags. A 5 s `sample` shows the main thread busy almost all
  the time: about 1,890 samples, only a handful idle in the run loop.
- It gets worse as the flight goes on: the recording holds about 578,000
  messages, of which about 521,000 are from our own aircraft (8.5 h).

## Where the main thread goes (5 s sample)

| Share | What |
|---|---|
| ~65 % | Swift Charts layout and drawing (`GeometryReader` → Charts internals) |
| ~25 % | `Dataset.samples(for:_:gap:)`: thinning each channel (`PlotStack.build`, `PlotPanel.swift:159–160`, `Dataset.swift:529`) |
| ~6 % | `Dataset.turbulence(for:)` → `Turbulence.analyse` (`PlotPanel.swift:54`, `Dataset.swift:399`) |
| ~4 % | `AppState.tick` → `refresh` / `refreshTrack` / `Dataset.track(for:until:)` / `simplifiedRuns` |

## Cause

- Every live batch from Redis calls `live.merge(batch)` and sets
  `AppState.revision` (`AppState.swift`, `onBatch`).
- `PlotStack.body` reads `state.revision`, so every batch rebuilds the whole
  panel.
- Both caches are keyed on the revision: `plotCache` in
  `Dataset.samples` and `turbulenceCache` in `Dataset.turbulence`. A new
  batch empties them. Each channel is then re-thinned over the whole flight,
  with up to 8 tolerance-doubling passes until at most
  `Dataset.maxPlotPoints = 3000` points remain. Turbulence is re-analysed
  over the whole flight too.
- Swift Charts then lays out up to 3,000 marks per line. There are about
  13 lines over the four groups (altitude, speed, vertical rate, directions),
  plus the turbulence and interrogation charts.
- The cost grows with the length of the recording, and the batches arrive
  several times per second, so the main thread never catches up.

## Context at the time

- The machine was short on memory: 116 MB free, 8.9 GB compressed, heavy
  swapping (Firefox about 1.7 GB, Flighty 275 MB).
- The datalink VDL2 decoder used about 99 % of a core and uplink1030 about
  41 %.

## Second symptom: the selected track is not drawn (23:40 UTC)

The aircraft moves, but its trajectory line does not appear. It had already
happened earlier in the flight.

- A new 4 s sample shows the main thread with **no idle sample at all**:
  - Swift Charts drawing about 32 %;
  - `PlotStack` rebuilding about 9 %;
  - `Dataset.track(for:until:)` (re-thinning the whole track, its cache
    keyed on `revision`) about 6 %;
  - add/remove overlay calls from `GlobeView.Coordinator.syncTrack`.
- `syncTrack` compares a signature per segment (point count, first and last
  time). In live mode the current segment gets a new last point at every
  batch, so its whole `MKPolyline` is removed and added again.
  - That is several times per second.
  - The segment holds every point since the last reception gap (17:08, so
    hours of track).
  - MapKit draws overlays asynchronously. With the main thread saturated and
    the overlay replaced before it is drawn, the line never shows. The older
    segments (before the 16:08 gap) keep their signature and stay drawn.
- **No workaround in the interface.** The plots are part of the selection
  card (`ContentView.swift`, `PlotStack` under the flight plan), and the
  track is drawn only for the selected aircraft. Deselecting removes both.

Fixes, on top of those below:

1. **Split the live segment.** Keep a frozen polyline for the points before
   the last few minutes, and replace only a short tail polyline at each
   update. Freeze a new chunk every few minutes.
2. **Cache the thinned runs incrementally** in `simplifiedRuns`: completed
   runs do not change, and only the last one grows.
3. **Collapse the plots, or make them opt-in,** in the selection card, so a
   selected aircraft does not cost the chart rebuilds.

## Workaround

Close the plot panel or deselect our aircraft: the charts are not built
any more.

## Fixes to consider

1. **Throttle the redraw.** The plots should follow a slow revision, for
   example updated at most every 2–5 s, instead of `revision` on every batch.
   The globe can keep the fast one.
2. **Incremental work.**
   - Thin only the new tail of each channel and append it to the cached
     result. Keep the earlier runs and redo the whole thinning only when the
     point budget is exceeded.
   - Turbulence: completed minutes do not change; analyse only the minutes
     after the last cached one.
3. **Fewer points.** A 130 px high chart a few hundred pixels wide needs
   about 500 points per line, not 3,000. Make the budget depend on the chart
   width.
4. **Visible range only.** Thin over `rangeStart…rangeEnd` rather than the
   whole dataset when zoomed in.
5. **Off the main thread.** Compute `PlotContent` in a background task and
   publish the result. The `body` should only draw.
6. **Measure.** Add signposts around `build`, `samples` and `turbulence`,
   then profile in Instruments, replaying the AF162 recording into Redis.
