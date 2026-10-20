# Changelog

## 0.2.1 - 2026-10-20

- Add an About popover to the telemetry panel with the app version, build number, release date, and project links.

## 0.2.0 - 2026-10-15

- Add a telemetry panel with separate RAM and GPU charts, 1-, 5-, and 15-minute history windows, current and peak utilization, and available memory.
- Add automatic chart scaling and a full 0–100% scale option.
- Let Preferences control whether the menu bar shows RAM, GPU, both readings, or an icon.
- Show connection health and sample age, add manual reconnect, and recover automatically from stale streams, connection failures, and wake from sleep.
- Add guided dashboard setup with a configurable local port, connection testing, NVIDIA Sync and SSH tunnel shortcuts, and inline sign-in errors.
- Keep saved dashboard sessions separate for each local port and support current KiB telemetry fields alongside older payloads.
- Add opt-in launch at login, a first-run welcome guide, and Preferences that adapt to the available screen space.
- Add a `--demo` mode for exploring telemetry without using saved dashboard credentials.
- Keep Preferences, Open Dashboard, and Quit available from the panel's actions menu.

## 0.1.0 - 2026-05-21

- Initial public release of PulseBar.
- Show local DGX Dashboard telemetry in the macOS menu bar.
- Add Sparkle-based app update support for signed direct-download builds.
- Add local release automation for signing, notarization, GitHub Releases, appcast generation, and release asset verification.
- Sign Sparkle helper tools correctly for notarized direct-download releases.
