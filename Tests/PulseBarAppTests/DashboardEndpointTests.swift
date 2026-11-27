import XCTest

@testable import PulseBarApp

final class DashboardEndpointTests: XCTestCase {
    @MainActor
    func testUnsignedSyncBundleIsRejectedEvenWithMatchingIdentifier() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = directory.appendingPathComponent("NVIDIA Sync.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = ["CFBundleIdentifier": "com.nvidia.nvidia-sync", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
            to: contents.appendingPathComponent("Info.plist"))
        XCTAssertFalse(DashboardSetupActions.isTrustedSync(at: app))
        XCTAssertFalse(DashboardSetupActions.isTrustedSync(at: URL(fileURLWithPath: "/usr/bin/true")))
    }

    func testConnectionAdviceUsesTheRequestedPort() throws {
        let message = DashboardConnectionMessage.message(
            for: URLError(.cannotConnectToHost), endpoint: try DashboardEndpoint(port: 11001, sshHost: "spark")
        )
        XCTAssertTrue(message.contains("127.0.0.1:11001"))
        XCTAssertTrue(message.contains("SSH access to spark"))
    }
    func testPortValidationAndLoopbackOnlyURLs() throws {
        XCTAssertEqual(try DashboardEndpoint.parse(" 11001 ").url.absoluteString, "http://127.0.0.1:11001")
        for value in ["", "abc", "0", "-1", "65536", "http://example.com", "11000/api/login"] {
            XCTAssertThrowsError(try DashboardEndpoint.parse(value), value)
        }
    }

    func testAliasesAndPortsIdentifySeparateSSHProfiles() throws {
        let endpoint = try DashboardEndpoint.parse(" 11000 ", sshHost: " dgx ")
        let other = try DashboardEndpoint(port: 11000, sshHost: "lab_2.example")
        let alternate = try DashboardEndpoint(port: 11001, sshHost: "dgx")
        for profile in [DashboardEndpoint.standard, other, alternate] {
            XCTAssertNotEqual(endpoint.sessionAccount, profile.sessionAccount)
            XCTAssertNotEqual(endpoint.usernameKey, profile.usernameKey)
            XCTAssertNotEqual(endpoint.reconnectPausedKey, profile.reconnectPausedKey)
        }

    }

    func testInvalidSSHAliasesAreRejectedBeforeOpeningAConnection() {
        for alias in ["", "-v", "a b", "user@host", "a/b", "a\nb", "é", String(repeating: "a", count: 254)] {
            XCTAssertThrowsError(try DashboardEndpoint(port: 11000, sshHost: alias), alias)
        }
    }

    @MainActor
    func testUsernamesStayIsolatedBetweenEndpoints() throws {
        let suite = "PulseBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DashboardSessionStore(endpoint: .standard, defaults: defaults)
        let second = DashboardSessionStore(endpoint: try DashboardEndpoint(port: 11001), defaults: defaults)
        first.saveUsername("alice")
        XCTAssertEqual(first.loadUsername(), "alice")
        XCTAssertEqual(second.loadUsername(), "")
        second.saveUsername("bob")
        XCTAssertEqual(first.loadUsername(), "alice")
    }

}
