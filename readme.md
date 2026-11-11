# travel

A macOS app that shows aircraft and ships on a globe, from
[jet1090](https://github.com/xoolive/jet1090) and
[ship162](https://github.com/xoolive/ship162) decoded messages.

It replays recordings and follows live feeds. The map fills the window; a
floating panel lists the sources, or shows the selected aircraft or ship with
its plots, and a state table can be laid over the map.

## Run

Requires macOS 14 or later and Xcode (Swift 6 toolchain).

```sh
./scripts/run.sh
```

The script builds the Swift package, wraps the binary in `build/Travel.app`
and opens it. Options are passed to the app:

```sh
./scripts/run.sh /path/to/recording.jsonl.zst    # open a recording
./scripts/run.sh --live                          # start the first live source
./scripts/run.sh --source redis://localhost:6379/jet1090,ship162
./scripts/run.sh /path/to/file.jsonl.zst --select 39c427 --speed 300
```

## Sources

- **Recordings**: drop `.jsonl`, `.jsonl.zst` or `.jsonl.7z` files written by
  `jet1090` or `ship162` on the window. Several recordings selected together in the sidebar
  are merged. A timeline replays them at 1× to 1000×.
- **Live**: Redis pub/sub channels carrying the same JSON messages. Sources
  are added, edited, started and stopped from the sidebar; the default is
  `127.0.0.1:6379` with channels `jet1090` and `ship162`.

## Views

- **Map**: a MapKit globe. Selecting a target draws its trajectory; reception
  gaps longer than five minutes are bridged with a dashed line.
- **Detail**: selecting a target turns the side panel into its current state
  and plots of altitude, speed, vertical rate and directions. Click or drag in
  a plot to move the clock.
- **Table**: sortable state table with the columns of the `jet1090` terminal
  interface, and a second table for ships.

## Layout

```text
Sources/Travel/   the app (SwiftUI, MapKit, Swift Charts)
scripts/run.sh    build, bundle and launch
scripts/make-icon.swift   draws Resources/AppIcon.icns
```

The app reads decoded JSON only: it does not decode radio signals itself.

## License

MIT, see [license.md](license.md).
