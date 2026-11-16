import Foundation
import XCTest

@testable import PulseBarApp

final class ConnectionIntegrationTests: XCTestCase {
    @MainActor
    func testLoginReachesLiveTelemetryAndPersistsSession() async throws {
        let server = try await DashboardFixture(scenario: .live)
        let session = URLSession(configuration: .ephemeral)
        let store = MemorySessionStore(username: "", token: nil)
        let model = MetricsViewModel(dashboard: DashboardClient(baseURL: server.url, session: session), sessionStore: store)
        defer {
            model.signOut()
            session.invalidateAndCancel()
            server.stop()
        }

        let connectionMessage = await model.testConnection()
        XCTAssertTrue(connectionMessage.hasPrefix("Dashboard page is reachable"))
        model.username = " demo \n"
        model.password = "demo"
        let task = try XCTUnwrap(model.signIn())
        await task.value
        try await waitUntil { model.connectionHealth.state == .live }

        XCTAssertTrue(model.isSignedIn)
        XCTAssertFalse(model.isAuthenticating)
        XCTAssertEqual(model.username, "demo")
        XCTAssertEqual(model.password, "")
        XCTAssertEqual(store.loadUsername(), "demo")
        XCTAssertEqual(store.token, "simulator-token")
    }

    @MainActor
    func testHTTPLoginFailuresDoNotPersistSession() async throws {
        for (scenario, password, expectedMessage) in [
            (.live, "incorrect-password", DashboardError.loginFailed.localizedDescription),
            (.loginError, "demo", "Authentication service unavailable."),
            (.loginInvalidResponse, "demo", nil),
        ] as [(DashboardFixture.Scenario, String, String?)] {
            let server = try await DashboardFixture(scenario: scenario)
            let session = URLSession(configuration: .ephemeral)
            let store = MemorySessionStore(username: "", token: nil)
            let model = MetricsViewModel(dashboard: DashboardClient(baseURL: server.url, session: session), sessionStore: store)
            defer {
                model.signOut()
                session.invalidateAndCancel()
                server.stop()
            }

            model.username = "demo"
            model.password = password
            let task = try XCTUnwrap(model.signIn())
            await task.value

            XCTAssertFalse(model.isSignedIn, scenario.rawValue)
            XCTAssertFalse(model.isAuthenticating, scenario.rawValue)
            XCTAssertEqual(model.password, "", scenario.rawValue)
            XCTAssertNil(store.token, scenario.rawValue)
            XCTAssertEqual(store.loadUsername(), "", scenario.rawValue)
            XCTAssertNotNil(model.snapshot.gpu.note, scenario.rawValue)
            if let expectedMessage { XCTAssertEqual(model.snapshot.gpu.note, expectedMessage, scenario.rawValue) }
        }
    }

    @MainActor
    func testMenuUsesLiveReadingsAfterConnectingAndRefreshing() async throws {
        let server = try await DashboardFixture(scenario: .live)
        let session = URLSession(configuration: .ephemeral)
        let model = MetricsViewModel(
            dashboard: DashboardClient(baseURL: server.url, session: session), sessionStore: MemorySessionStore())
        defer {
            model.signOut()
            session.invalidateAndCancel()
            server.stop()
        }

        XCTAssertEqual(model.connectionHealth.state, .connecting)
        XCTAssertEqual(model.snapshot.menuBarTitle, "RAM -- GPU --")
        try await waitUntil { model.connectionHealth.state == .live }
        XCTAssertEqual(model.connectionHealth.state, .live)
        XCTAssertNotNil(model.connectionHealth.lastSampleAt)
        XCTAssertNotEqual(model.snapshot.menuBarTitle, "RAM -- GPU --")

        model.refresh()
        XCTAssertEqual(model.connectionHealth.state, .reconnecting)
        XCTAssertEqual(model.snapshot.gpu.note, "Reconnecting to the local dashboard…")
        XCTAssertEqual(model.snapshot.menuBarTitle, "RAM -- GPU --")
        try await waitUntil { model.connectionHealth.state == .live }
        XCTAssertNotEqual(model.snapshot.menuBarTitle, "RAM -- GPU --")
    }

    @MainActor
    func testCarriageReturnLineEndingsDeliverTelemetry() async throws {
        for scenario in [DashboardFixture.Scenario.carriageReturnOnly, .carriageReturnLineFeed] {
            let server = try await DashboardFixture(scenario: scenario)
            let session = URLSession(configuration: .ephemeral)
            let model = MetricsViewModel(
                dashboard: DashboardClient(baseURL: server.url, session: session), sessionStore: MemorySessionStore())
            defer {
                model.signOut()
                session.invalidateAndCancel()
                server.stop()
            }
            try await waitUntil { model.connectionHealth.state == .live }
            XCTAssertEqual(model.snapshot.menuBarTitle, "RAM 50% GPU 37%", scenario.rawValue)
        }
    }

    @MainActor
    func testMalformedEventDoesNotPreventFollowingSample() async throws {
        let server = try await DashboardFixture(scenario: .malformedThenLive)
        let session = URLSession(configuration: .ephemeral)
        let model = MetricsViewModel(
            dashboard: DashboardClient(baseURL: server.url, session: session), sessionStore: MemorySessionStore())
        defer {
            model.signOut()
            session.invalidateAndCancel()
            server.stop()
        }

        try await waitUntil { model.connectionHealth.state == .live }
        XCTAssertEqual(model.snapshot.menuBarTitle, "RAM 50% GPU 37%")
    }

    @MainActor
    func testHeartbeatOnlyStreamClearsReadingsAndRestartsWhenStale() async throws {
        let server = try await DashboardFixture(scenario: .heartbeatOnly)
        let session = URLSession(configuration: .ephemeral)
        let model = MetricsViewModel(
            dashboard: DashboardClient(baseURL: server.url, session: session), sessionStore: MemorySessionStore())
        defer {
            model.signOut()
            session.invalidateAndCancel()
            server.stop()
        }

        try await waitUntil { model.connectionHealth.state == .waiting }
        XCTAssertNil(model.connectionHealth.lastSampleAt)
        model.checkFreshness(at: Date().addingTimeInterval(31))
        XCTAssertEqual(model.connectionHealth.state, .stale)
        XCTAssertEqual(model.snapshot.gpu.note, "Telemetry is stale. Reconnecting…")
        XCTAssertEqual(model.snapshot.menuBarTitle, "RAM -- GPU --")
        try await waitUntil { model.connectionHealth.state == .waiting }
    }

    @MainActor
    func testUnauthorizedSessionUpdatesTheWholeMenu() async throws {
        let server = try await DashboardFixture(scenario: .unauthorized)
        let session = URLSession(configuration: .ephemeral)
        let store = MemorySessionStore()
        let model = MetricsViewModel(dashboard: DashboardClient(baseURL: server.url, session: session), sessionStore: store)
        defer {
            model.signOut()
            session.invalidateAndCancel()
            server.stop()
        }

        XCTAssertTrue(model.isSignedIn)
        try await waitUntil { model.connectionHealth.state == .expired }
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(store.token)
        XCTAssertEqual(model.snapshot.menuBarTitle, "RAM -- GPU --")
        XCTAssertEqual(model.snapshot.gpu.note, "Your dashboard session expired. Sign in again.")
    }

    @MainActor
    func testCancelledStreamCannotRestoreReadingsAfterSignOut() async throws {
        let server = try await DashboardFixture(scenario: .live)
        let session = URLSession(configuration: .ephemeral)
        let model = MetricsViewModel(
            dashboard: DashboardClient(baseURL: server.url, session: session), sessionStore: MemorySessionStore())
        defer {
            model.signOut()
            session.invalidateAndCancel()
            server.stop()
        }

        try await waitUntil { model.connectionHealth.state == .live }
        model.signOut()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.connectionHealth.state, .signedOut)
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(model.connectionHealth.lastSampleAt)
        XCTAssertEqual(model.snapshot.menuBarTitle, "RAM -- GPU --")
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                throw FixtureError.timeout
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class MemorySessionStore: DashboardSessionStoring {
    private var username: String
    private(set) var token: String?
    init(username: String = "demo", token: String? = "simulator-token") {
        self.username = username
        self.token = token
    }
    func loadUsername() -> String { username }
    func saveUsername(_ username: String) { self.username = username }
    func clearUsername() { username = "" }
    func loadToken() -> String? { token }
    func saveToken(_ token: String) { self.token = token }
    func clearToken() { token = nil }
}

private enum FixtureError: Error {
    case timeout
}
