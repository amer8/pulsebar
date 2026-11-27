import AppKit
import Foundation
import PulseBarUI
import Security

struct DashboardEndpoint: Hashable, Sendable {
    let port: Int
    let sshHost: String?
    static let preferenceKey = "PulseBar.Dashboard.Port"
    static let hostPreferenceKey = "PulseBar.Dashboard.SSHHost"
    static let standard = try! DashboardEndpoint(port: DashboardPreferencesState.defaultDashboardPort)

    init(port: Int, sshHost: String? = nil) throws {
        guard (1...65535).contains(port) else { throw DashboardError.server("Port must be between 1 and 65535.") }
        if let sshHost {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            guard (1...253).contains(sshHost.utf8.count), sshHost.first != "-", sshHost.unicodeScalars.allSatisfy(allowed.contains)
            else {
                throw DashboardError.server("Enter a host alias from ~/.ssh/config using letters, digits, dots, underscores or hyphens.")
            }
        }
        self.port = port
        self.sshHost = sshHost
    }

    static func parse(_ text: String, sshHost: String? = nil) throws -> DashboardEndpoint {
        guard let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DashboardError.server("Enter a numeric dashboard port.")
        }
        return try DashboardEndpoint(port: port, sshHost: sshHost?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static var current: DashboardEndpoint { saved(in: .standard) }

    static func saved(in defaults: UserDefaults) -> DashboardEndpoint {
        (try? DashboardEndpoint(
            port: defaults.integer(forKey: preferenceKey), sshHost: defaults.string(forKey: hostPreferenceKey)))
            ?? .standard
    }
    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var profileLabel: String? { sshHost.map { "\($0) · \(port)" } }
    var address: String { "127.0.0.1:\(port)" }
    static func verifiedSSHArguments(for host: String) -> [String] {
        [
            "-S", "none", "-o", "ControlMaster=no", "-o", "StrictHostKeyChecking=yes",
            "-o", "HostKeyAlias=\(host)", "-o", "VerifyHostKeyDNS=no", "-o", "KnownHostsCommand=none",
            "-o", "NoHostAuthenticationForLocalhost=no", "-o", "NoHostAuthenticationForProxyCommand=no",
            "-o", "UpdateHostKeys=no",
        ]
    }

    private var profile: String { "ssh:\(sshHost ?? ""):\(port)" }
    var sessionAccount: String { "dashboard-token:\(profile)" }
    var usernameKey: String { "PulseBar.Dashboard.Username.\(profile)" }
    var reconnectPausedKey: String { "PulseBar.Dashboard.ReconnectPaused.\(profile)" }

    func matches(portText: String, sshHost: String? = nil) -> Bool { (try? Self.parse(portText, sshHost: sshHost)) == self }
}

struct DashboardReconnectPauseStore {
    var defaults: UserDefaults = .standard

    func isPaused(for endpoint: DashboardEndpoint) -> Bool {
        defaults.bool(forKey: endpoint.reconnectPausedKey)
    }

    func setPaused(_ paused: Bool, for endpoint: DashboardEndpoint) {
        if paused {
            defaults.set(true, forKey: endpoint.reconnectPausedKey)
        } else {
            defaults.removeObject(forKey: endpoint.reconnectPausedKey)
        }
    }
}

@MainActor
enum DashboardSetupActions {
    // NVIDIA Sync's Developer ID designated requirement, including its publisher's team.
    private static let identifiers = ["com.nvidia.nvidia-sync", "com.nvidia.sync", "com.nvidia.NVIDIASync"]

    static func isTrustedSync(at url: URL) -> Bool {
        let products = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        let expression =
            "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
            + "and certificate leaf[subject.OU] = \"6KR3T733EC\" and (\(products))"
        var requirement: SecRequirement?
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
            SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code
        else { return false }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    static func openSync() async -> Bool {
        let workspace = NSWorkspace.shared
        let installations = ["/Applications", NSHomeDirectory() + "/Applications"].map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("NVIDIA Sync.app", isDirectory: true)
        }
        guard
            let trusted = installations.first(where: {
                $0.resolvingSymlinksInPath().path == $0.path && isTrustedSync(at: $0)
            })
        else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.allowsRunningApplicationSubstitution = false
        return (try? await workspace.openApplication(at: trusted, configuration: configuration)) != nil
    }
}
