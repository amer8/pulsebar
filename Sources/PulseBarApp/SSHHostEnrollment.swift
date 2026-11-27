import Foundation

/// Only OpenSSH negotiates and records keys. Its ask mode rejects changed keys and accepts
/// an exact SHA256 fingerprint as the answer to the *new host* confirmation prompt.
struct SSHHostEnrollment: Sendable {
    let host: String
    var config: URL?

    @MainActor func presentedFingerprint(confirming expected: String? = nil) async throws -> String {
        _ = try DashboardEndpoint(port: 1, sshHost: host)
        if let expected, !Self.validFingerprint(expected) {
            throw DashboardError.server("Enter the SHA256 fingerprint from the device’s console or its administrator.")
        }
        let configArguments = config.map { ["-F", $0.path] } ?? []
        try await DashboardSSHTransport.requireConfiguredAlias(host, configArguments: configArguments)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("confirm")
        let prompt = directory.appendingPathComponent("prompt")
        let script = #"""
            #!/bin/sh
            case "$1" in
              *'keys of different type are already known'*) exit 1 ;;
              *'Are you sure you want to continue connecting (yes/no/[fingerprint])?'*)
                printf '%s' "$1" > "$PULSEBAR_SSH_PROMPT"
                case "$1" in
                  *"$PULSEBAR_SSH_FINGERPRINT"*) printf '%s\n' "$PULSEBAR_SSH_FINGERPRINT" ;;
                  *) printf 'no\n' ;;
                esac ;;
              *) exit 1 ;;
            esac
            """#
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // Command-line options take their first value. Only the enrollment invocation uses ask.
        process.arguments =
            configArguments + ["-o", "StrictHostKeyChecking=ask"] + DashboardEndpoint.verifiedSSHArguments(for: host) + [
                "-T", "-a", "-x", "-o", "BatchMode=no", "-o", "PreferredAuthentications=none", "-o", "FingerprintHash=sha256",
                "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none", "-o", "SessionType=default",
                "-o", "ForkAfterAuthentication=no", "-o", "ConnectionAttempts=1", "-o", "ConnectTimeout=8", "--", host, "true",
            ]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["SSH_ASKPASS"] = helper.path
        environment["DISPLAY"] = "pulsebar"
        environment["PULSEBAR_SSH_PROMPT"] = prompt.path
        environment["PULSEBAR_SSH_FINGERPRINT"] = expected ?? "no"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        let timeout = Task {
            try await Task.sleep(for: .seconds(20))
            if process.isRunning { process.terminate() }
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            Task { @MainActor in if process.isRunning { process.terminate() } }
        }
        try Task.checkCancellation()
        let message = (try? String(contentsOf: prompt, encoding: .utf8)) ?? ""
        for line in message.split(whereSeparator: \.isNewline) {
            guard let marker = line.range(of: #" key fingerprint is:? "#, options: .regularExpression) else { continue }
            let fingerprint = String(line[marker.upperBound...].drop(while: { $0 == " " })).trimmingCharacters(
                in: CharacterSet(charactersIn: "."))
            guard Self.validFingerprint(fingerprint), expected == nil || expected == fingerprint else { break }
            return fingerprint
        }
        throw DashboardError.server("Could not confirm this host key. Connect again to check its current SSH identity.")
    }

    static func validFingerprint(_ value: String) -> Bool {
        value.range(of: #"\ASHA256:[A-Za-z0-9+/]{43}\z"#, options: .regularExpression) != nil
    }
}
