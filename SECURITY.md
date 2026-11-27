# Security

PulseBar is local-first. It communicates with the DGX Dashboard through the configured SSH alias, stores the dashboard username in `UserDefaults`, and stores the dashboard auth token in the macOS Keychain.

## Privacy

- The alias chooser reads literal host aliases from `~/.ssh/config` and its included files. PulseBar treats these files as read-only.
- PulseBar uses macOS OpenSSH to authenticate the DGX against its trusted host key under the selected alias. Unknown keys stop dashboard requests. During guided enrollment, OpenSSH can record a new key in the SSH known-hosts file after the user supplies its independently verified SHA256 fingerprint. Changed keys stop setup. Verify key changes independently before updating your SSH trust store.
- After SSH starts the remote command, PulseBar sends dashboard credentials over encrypted standard input. The remote curl process connects to HTTP loopback on the authenticated DGX. The DGX account, its SSH configuration, and the dashboard listener on that machine are part of the trust boundary.
- Each alias and dashboard port has its own Keychain token, saved username, and reconnect setting. After five consecutive telemetry failures, authenticated polling pauses for that profile until you choose **Reconnect**. Sign out before reassigning an alias to a different machine.
- Upgrading requires a fresh sign-in. Port-only tokens from earlier versions stay unused in Keychain. You can delete those items in Keychain Access under `PulseBar.Dashboard`. Sign out of each current profile to remove its token before uninstalling.
- The connection check must succeed for the selected host and port before a new profile can sign in. Dashboard requests use no cookie jar. PulseBar clears telemetry history when the session expires or you sign out.
- The telemetry panel hands off browser access to NVIDIA Sync. Device setup also offers to open Sync for SSH configuration. PulseBar passes no dashboard credentials or profile settings to it. **Open NVIDIA Sync** checks the application's NVIDIA Developer ID signature and opens a verified installation from `/Applications` or `~/Applications`.
- No telemetry is sent to a third-party service by PulseBar.
- Diagnostics are written to the macOS unified system log.

## Reporting A Vulnerability

If you believe you have found a security issue, avoid posting credentials, tokens, or sensitive dashboard details in public reports. Use GitHub private vulnerability reporting if it is enabled for this repository, or open an issue with sensitive details omitted.
