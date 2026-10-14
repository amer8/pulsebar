# Contributing

Thanks for taking the time to improve PulseBar.

## Development Setup

You need macOS 13 Ventura or newer and the Swift 6 toolchain.

For manual testing, keep a local DGX Dashboard reachable at `http://127.0.0.1:11000` through either NVIDIA Sync or a manual SSH tunnel, then sign in with valid dashboard credentials.

Run from source:

```bash
swift build
swift run PulseBar
```

To run from Xcode, open `Package.swift` as a Swift package and run the `PulseBar` executable target.

## Local App Builds

Build a release `.app` bundle and copy it to `~/Applications`:

```bash
make install
```

The installed app is `~/Applications/PulseBar.app`. To remove it:

```bash
make uninstall
```

Build the release DMG locally:

```bash
make dmg
```

The generated disk image is written to `.build/release/artifacts/PulseBar-<version>.dmg`.

Local unsigned builds keep the updater disabled. Signed direct-download builds can check for app updates from the PulseBar menu.

## Checks

```bash
make format
make check
make readme-assets
```

`make check` runs the same gates used by CI:

- `swift format lint --strict` with the checked-in `.swift-format` configuration.
- `swift build -Xswiftc -warnings-as-errors`.
- `swift test -Xswiftc -warnings-as-errors`.
- `swift run --skip-build PulseBar --check-runtime` to verify dynamic frameworks load without opening the UI.

The GitHub Actions workflow at `.github/workflows/quality.yml` runs on pull requests, pushes to `main`, and manual dispatches.

## Telemetry Contract

The current implementation expects `gpu_telemetry` SSE events shaped like this:

```json
{
  "TelemetryForGPUs": [
    {
      "percentage_utilization": 37.0,
      "memory_total_in_mb": 65536,
      "memory_available_in_mb": 32768
    }
  ]
}
```

`percentage_utilization` drives the GPU figure. The menu bar `RAM` value is derived from the streamed `memory_total_in_mb` and `memory_available_in_mb` fields, so PulseBar reflects the dashboard payload rather than a separate macOS system probe.

## Project Notes

- Keep changes focused and consistent with the existing Swift package app structure.
- Do not commit local build artifacts from `.build/`.

## Connection Health Feature

This independent branch adds connection state, the last-sample timestamp, and a Reconnect
action to the existing menu. It detects stale telemetry after 30 seconds, uses bounded
reconnect delays, and reconnects after wake.

The connection integration tests require `python3` and start disposable simulator servers
on OS-assigned loopback ports. They exercise live readings, reconnect, stale streams,
session expiry, and sign-out using in-memory credentials rather than your saved session.
Telemetry accepts the current dashboard's KiB memory fields and the older MB fields.
The simulator emits KiB by default; use `--memory-units mb` to exercise legacy compatibility.

Run `make check` and `swift run PulseBar`. For a local fixture, run
`python3 Scripts/dashboard-simulator.py --port 11000` in another terminal and sign in with
`demo` / `demo`. Use `--scenario heartbeat-only`, `disconnect`, `unauthorized`, or `malformed`
to exercise failures. Connection health is part of the merged main branch.

## Guided Setup Feature

This independent branch adds a local-port setting, a dashboard connection check, NVIDIA
Sync and SSH setup actions, and inline login errors. Saved sessions are isolated by port.
Run `make check` and `swift run PulseBar`. For a local fixture, run
`python3 Scripts/dashboard-simulator.py --port 11001` in another terminal, set port 11001
in Preferences, and sign in with `demo` / `demo`. The existing telemetry menu is retained.

Preferences uses compact connection, account, and diagnostics cards. The app and standalone Preferences
renderer share the same SwiftUI layout in `Sources/PulseBarUI`. To inspect signed-in,
sign-in, and invalid-port states in both light and dark mode without saved credentials:

```bash
swift run pulsebar-tools render-preferences-previews
```

The previews are saved in `.build/preferences-previews/`. This feature keeps the README
image, caption, and image dimensions identical to `main`.
