# Changelog

## 0.3.0 - Unreleased

### Monitor multiple devices

PulseBar now tracks RAM and GPU usage on multiple devices at once. Click the device name at the top of the telemetry panel and choose another device to switch the charts and menu bar readings. Each device keeps collecting its own history while you view another.

### After updating

If you used a local port to connect, open Preferences → Devices. “+ Add new” opens the device picker. Choose a saved SSH alias to start verification, or use “Set up a device in NVIDIA Sync…” if yours is missing. If asked to verify the device, enter the SSH fingerprint from its console or your administrator. Then sign in to DGX Dashboard once to resume telemetry.

### What changed

- Both pickers list only devices added to PulseBar and show the Dashboard username for each signed-in device. PulseBar treats your SSH configuration as read-only. In Preferences → Devices, select a device to manage its account. The Settings section shows the DGX Dashboard port and identifies its default value. Signing out clears only that device’s saved session.
- PulseBar verifies your device’s SSH host key before sending dashboard credentials. It remembers your sign-in separately for each connection and dashboard port.
- Saved sessions restore without Keychain prompts at startup. If a device needs permission, choose Restore Saved Session for that device in Preferences → Devices. New Keychain entries show the device name in the permission prompt.
- To use the dashboard in your browser, choose Open NVIDIA Sync from the telemetry panel’s ⋯ menu, then select your device and open its dashboard.
- While the selected device reconnects, the menu bar shows its connection status in place of old RAM and GPU readings.
- The menu bar update icon and the panel’s update banner clear when DGX Dashboard reports no available system updates.

## 0.2.5 - 2026-11-19

- The menu bar warns you when you need to reconnect or sign in again.
- See available DGX system updates in the menu bar. If a check fails, PulseBar marks the last result as out of date.
- The telemetry panel now has a translucent background on supported macOS versions.
- PulseBar sends your sign-in details only to your configured dashboard and rejects invalid session tokens.

## 0.2.4 - 2026-11-16

- After repeated connection failures, automatic retries pause until you choose Reconnect, even after an app restart.
- Live readings continue when the dashboard sends an invalid sample.
- Cancelling a connection no longer adds extra delay to the next retry.
- The setup guide now explains the Apple silicon requirement and how PulseBar protects local dashboard connections.

## 0.2.3 - 2026-11-12

- PulseBar remembers your selected time range and chart scale between launches.
- Hover over a RAM or GPU chart to see a reading and its timestamp.
- About PulseBar and Reconnect are now in the panel’s ··· menu.
- PulseBar handles Keychain errors more reliably when restoring a saved dashboard session.

## 0.2.2 - 2026-10-23

- Upgrade Sparkle to 2.10.0.
- Keep the RAM percentage consistent between the menu bar and history when reported memory capacity is fractional.
- Cancel pending sign-ins on sign-out and ignore late responses so they cannot restore or replace a newer session.
- Add authentication and session-storage regression tests, including rejected credentials and token-save failures.
- Replace the Python dashboard simulator with a Swift test fixture, removing Python from the test requirements.

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
