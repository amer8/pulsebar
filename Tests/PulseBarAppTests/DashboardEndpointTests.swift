import XCTest

@testable import PulseBarApp

final class DashboardEndpointTests: XCTestCase {
    func testConnectionAdviceUsesTheRequestedPort() throws {
        let message = DashboardConnectionMessage.message(
            for: URLError(.cannotConnectToHost), syncAppState: .notRunning, endpoint: try DashboardEndpoint(port: 11001)
        )
        XCTAssertTrue(message.contains("127.0.0.1:11001"))
        XCTAssertTrue(message.contains("ssh -L 11001:localhost:11000"))
    }
    func testPortValidationAndLoopbackOnlyURLs() throws {
        XCTAssertEqual(try DashboardEndpoint.parse(" 11001 ").url.absoluteString, "http://127.0.0.1:11001")
        for value in ["", "abc", "0", "-1", "65536", "http://example.com", "11000/api/login"] {
            XCTAssertThrowsError(try DashboardEndpoint.parse(value), value)
        }
    }

    func testCredentialsAreScopedAndDefaultKeysRemainCompatible() throws {
        let standard = DashboardEndpoint.standard
        let other = try DashboardEndpoint(port: 11001)
        XCTAssertEqual(standard.sessionAccount, "dashboard-token")
        XCTAssertEqual(standard.usernameKey, "PulseBar.Dashboard.Username")
        XCTAssertNotEqual(standard.sessionAccount, other.sessionAccount)
        XCTAssertNotEqual(standard.usernameKey, other.usernameKey)
        XCTAssertEqual(other.tunnelCommand, "ssh -L 11001:localhost:11000 <username>@<IP-or-spark-hostname.local>")
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
