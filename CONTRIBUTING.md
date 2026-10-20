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

## Publishing a Release

1. Set `MARKETING_VERSION` and a numeric `BUILD_NUMBER` in `version.env`. The build number must exceed every published build. Keep the version fields in `Packaging/Info.plist` in sync.
2. Add a dated section for the version at the top of `CHANGELOG.md`, then run `make check`.
3. Set `CODESIGN_IDENTITY` to a Developer ID Application certificate and `SPARKLE_PUBLIC_ED_KEY` to the existing Sparkle public key. The default notarization Keychain profile is `pulsebar-notary`; override it with `NOTARY_PROFILE` if needed.
4. Run `make release-artifacts`. It signs and notarizes the app, staples its ticket, packages the ZIP and dSYM, and creates and notarizes the DMG. Artifacts are written to `.build/release/artifacts/`.
5. Generate release notes with `swift run pulsebar-tools generate-release-notes <version> <output.md>`. Generate the Sparkle appcast from the final ZIP using the existing signing key, and verify its version, build number, download URL, signature, and archive size. Sparkle's `generate_appcast` tool can use the Keychain directly.
6. Commit the release metadata, push the release commit and its `v<version>` tag, and publish a GitHub release containing the app ZIP, dSYM ZIP, and DMG. Publish the updated `appcast.xml` after the download assets are available.
7. Run `swift run pulsebar-tools check-release-assets v<version>`. Update `Casks/pulsebar.rb` in `amer8/homebrew-tap` with the version and the final DMG's SHA-256 checksum.

Preserve the existing Sparkle signing key so installed copies can verify updates.

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

Connection health includes connection state, the last-sample timestamp, and a Reconnect
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

Guided setup includes a local-port setting, a dashboard connection check, NVIDIA
Sync and SSH setup actions, and inline login errors. Saved sessions are isolated by port.
Run `make check` and `swift run PulseBar`. For a local fixture, run
`python3 Scripts/dashboard-simulator.py --port 11001` in another terminal, set port 11001
in Preferences, and sign in with `demo` / `demo`. The existing telemetry menu is retained.

Preferences uses compact connection and account cards. The app and standalone Preferences
renderer share the same SwiftUI layout in `Sources/PulseBarUI`. To inspect signed-in,
sign-in, and invalid-port states in both light and dark mode without saved credentials:

```bash
swift run pulsebar-tools render-preferences-previews
```

The previews are saved in `.build/preferences-previews/`. This feature keeps the README
image, caption, and image dimensions identical to `main`.

## Launch at Login Feature

Launch at login includes opt-in startup registration, actual macOS registration status,
approval and error feedback, and a first-run welcome in Preferences. Run `make check` for
the fake-service tests. Run `make install` and open `~/Applications/PulseBar.app` to test
registration from an installed app. It uses the original telemetry menu and dashboard
connection settings. The tests do not register a real login item.

Preferences starts at a compact width and fits its rendered content, including the welcome
guide, sign-in fields, and status messages. Its complete window frame is capped by the
current display's usable area; smaller displays retain scrolling. Content changes and
display changes trigger a refit, and narrower layouts stack connection actions.

`swift run pulsebar-tools render-preferences-previews` also verifies larger body text,
narrow and short displays, and writes the measured content and window sizes to
`.build/preferences-previews/layout.json`.

## Telemetry History Feature

Telemetry history includes a live panel with bounded RAM/GPU charts, time windows, peaks,
free memory, and menu-bar display options in Preferences. The panel also shows connection status and
a Reconnect action inherited from main. Run `make check` and `swift run PulseBar --demo`
for synthetic telemetry without reading saved dashboard credentials. Omit `--demo` to use
the dashboard at port 11000. The demo is specific to this branch.

The panel has an explicit opening viewport so the menu-bar window cannot collapse its
scroll view. Layout regression tests exercise compressed opening sizes and repeated opens.
To capture the actual app panel during layout regression tests:

```bash
mkdir -p .build/history-panel-previews
PULSEBAR_LAYOUT_PREVIEW_DIR="$PWD/.build/history-panel-previews" swift test --filter MetricsDetailLayoutTests
```

The panel and README preview share `TelemetryHistoryPanel` in `Sources/PulseBarUI`.
`swift run pulsebar-tools render-readme-assets` generates `docs/assets/menu-preview.png`
at 830 × 488 pixels for the README and `docs/assets/social-preview.png` at 640 × 320 pixels
for social previews. Both show the telemetry panel with the About popover closed.
The Trends layout puts current readings and peaks beside separate RAM/GPU charts.
Auto scales start at zero, with a minimum 5% range; the scale button switches both charts
to 0–100% for comparison. Relative time labels avoid clipped clock labels. The Menu Bar
card in Preferences retains the existing display preference, so previously selected modes
continue to apply.

The actions menu (⋯) in the panel header opens Preferences or the dashboard and quits
PulseBar. Preferences and Quit also retain their ⌘, and ⌘Q shortcuts.

The info button (ⓘ) beside the actions menu opens a compact About popover with the app
icon, version and build, release date, and project links. Version information comes from
the running app bundle. Packaging stamps `PulseBarReleaseDate` from the dated changelog
section for `APP_VERSION`; `RELEASE_DATE` can override it. Source runs show “Development
build” when bundle metadata is unavailable. Render the shared About content in light and
dark mode with `swift run pulsebar-tools render-about-previews`; images are saved in
`.build/about-previews/`.

To render the shared panel in light and dark mode with live, low-use, full-scale,
reconnecting, and signed-out sample states, run `swift run pulsebar-tools render-history-previews`.
Images are saved in `.build/history-panel-previews/`.
