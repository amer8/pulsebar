import AppKit
import Foundation

struct DashboardEndpoint: Equatable, Sendable {
    let port: Int
    static let preferenceKey = "PulseBar.Dashboard.Port"
    static let standard = try! DashboardEndpoint(port: 11000)

    init(port: Int) throws {
        guard (1...65535).contains(port) else { throw DashboardError.server("Port must be between 1 and 65535.") }
        self.port = port
    }

    static func parse(_ text: String) throws -> DashboardEndpoint {
        guard let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DashboardError.server("Enter a numeric dashboard port.")
        }
        return try DashboardEndpoint(port: port)
    }

    static var current: DashboardEndpoint {
        (try? DashboardEndpoint(port: UserDefaults.standard.integer(forKey: preferenceKey))) ?? .standard
    }
    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var address: String { "127.0.0.1:\(port)" }
    var tunnelCommand: String { "ssh -L \(port):localhost:11000 <username>@<IP-or-spark-hostname.local>" }
    var sessionAccount: String { port == 11000 ? "dashboard-token" : "dashboard-token:\(port)" }
    var usernameKey: String { port == 11000 ? "PulseBar.Dashboard.Username" : "PulseBar.Dashboard.Username.\(port)" }

    func save() { UserDefaults.standard.set(port, forKey: Self.preferenceKey) }
}

@MainActor
enum DashboardSetupActions {
    static func openSync() -> Bool {
        let workspace = NSWorkspace.shared
        let installed = ["com.nvidia.sync", "com.nvidia.NVIDIASync"].compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        if let url = installed.first { return workspace.open(url) }
        for directory in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("NVIDIA Sync.app")
            if FileManager.default.fileExists(atPath: url.path) { return workspace.open(url) }
        }
        return false
    }
    static func copyTunnel(_ endpoint: DashboardEndpoint) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint.tunnelCommand, forType: .string)
    }
}
