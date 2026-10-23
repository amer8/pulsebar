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
        let menu = MetricsMenuView(viewModel: model)
        defer {
            model.signOut()
            session.invalidateAndCancel()
            server.stop()
        }

        XCTAssertEqual(menu.menuState.connectionHealth.state, .connecting)
        XCTAssertEqual(menu.menuState.snapshot.menuBarTitle, "RAM -- GPU --")
        try await waitUntil { model.connectionHealth.state == .live }
        XCTAssertEqual(menu.menuState.connectionHealth.state, .live)
        XCTAssertNotNil(menu.menuState.connectionHealth.lastSampleAt)
        XCTAssertEqual(menu.menuState.snapshot.menuBarTitle, model.snapshot.menuBarTitle)
        XCTAssertNotEqual(menu.menuState.snapshot.menuBarTitle, "RAM -- GPU --")
        XCTAssertTrue(model.debugMessages.contains { $0.contains("Received telemetry sample") })

        model.refresh()
        XCTAssertEqual(menu.menuState.connectionHealth.state, .reconnecting)
        XCTAssertEqual(menu.menuState.snapshot.gpu.note, "Reconnecting to the local dashboard…")
        XCTAssertEqual(menu.menuState.snapshot.menuBarTitle, "RAM -- GPU --")
        try await waitUntil { model.connectionHealth.state == .live }
        XCTAssertNotEqual(menu.menuState.snapshot.menuBarTitle, "RAM -- GPU --")
    }

    @MainActor
    func testHeartbeatOnlyStreamClearsReadingsAndRestartsWhenStale() async throws {
        let server = try await DashboardFixture(scenario: .heartbeatOnly)
        let session = URLSession(configuration: .ephemeral)
        let model = MetricsViewModel(
            dashboard: DashboardClient(baseURL: server.url, session: session), sessionStore: MemorySessionStore())
        let menu = MetricsMenuView(viewModel: model)
        defer {
            model.signOut()
            session.invalidateAndCancel()
            server.stop()
        }

        try await waitUntil { model.connectionHealth.state == .waiting }
        XCTAssertNil(menu.menuState.connectionHealth.lastSampleAt)
        model.checkFreshness(at: Date().addingTimeInterval(31))
        XCTAssertEqual(menu.menuState.connectionHealth.state, .stale)
        XCTAssertEqual(menu.menuState.snapshot.gpu.note, "Telemetry is stale. Reconnecting…")
        XCTAssertEqual(menu.menuState.snapshot.menuBarTitle, "RAM -- GPU --")
        try await waitUntil { model.connectionHealth.state == .waiting }
        XCTAssertTrue(model.debugMessages.contains { $0.contains("Telemetry stream responded with HTTP 200") })
    }

    @MainActor
    func testUnauthorizedSessionUpdatesTheWholeMenu() async throws {
        let server = try await DashboardFixture(scenario: .unauthorized)
        let session = URLSession(configuration: .ephemeral)
        let store = MemorySessionStore()
        let model = MetricsViewModel(dashboard: DashboardClient(baseURL: server.url, session: session), sessionStore: store)
        let menu = MetricsMenuView(viewModel: model)
        defer {
            model.signOut()
            session.invalidateAndCancel()
            server.stop()
        }

        XCTAssertTrue(menu.menuState.isSignedIn)
        try await waitUntil { model.connectionHealth.state == .expired }
        XCTAssertFalse(menu.menuState.isSignedIn)
        XCTAssertNil(store.token)
        XCTAssertEqual(menu.menuState.snapshot.menuBarTitle, "RAM -- GPU --")
        XCTAssertEqual(menu.menuState.snapshot.gpu.note, "Your dashboard session expired. Sign in again.")
    }

    @MainActor
    func testCancelledStreamCannotRestoreReadingsAfterSignOut() async throws {
        let server = try await DashboardFixture(scenario: .live)
        let session = URLSession(configuration: .ephemeral)
        let model = MetricsViewModel(
            dashboard: DashboardClient(baseURL: server.url, session: session), sessionStore: MemorySessionStore())
        let menu = MetricsMenuView(viewModel: model)
        defer {
            model.signOut()
            session.invalidateAndCancel()
            server.stop()
        }

        try await waitUntil { model.connectionHealth.state == .live }
        model.signOut()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(menu.menuState.connectionHealth.state, .signedOut)
        XCTAssertFalse(menu.menuState.isSignedIn)
        XCTAssertNil(menu.menuState.connectionHealth.lastSampleAt)
        XCTAssertEqual(menu.menuState.snapshot.menuBarTitle, "RAM -- GPU --")
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
