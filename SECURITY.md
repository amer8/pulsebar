# Security

PulseBar is local-first. It communicates with the local DGX Dashboard endpoint configured in the app, stores the dashboard username in `UserDefaults`, and stores the dashboard auth token in the macOS Keychain.

## Privacy

- The dashboard uses plain HTTP on loopback. PulseBar sends the password and auth token to whichever process is listening on the configured local port; it cannot verify that process is the intended dashboard or SSH tunnel.
- After five consecutive telemetry failures, PulseBar pauses authenticated polling for that local port, including after an app restart, until the user selects Reconnect from the actions menu.
- The auth token is stored as a generic password item in the macOS Keychain.
- No telemetry is sent to a third-party service by PulseBar.
- Diagnostics are written to the macOS unified system log.

## Reporting A Vulnerability

If you believe you have found a security issue, avoid posting credentials, tokens, or sensitive dashboard details in public reports. Use GitHub private vulnerability reporting if it is enabled for this repository, or open an issue with sensitive details omitted.
