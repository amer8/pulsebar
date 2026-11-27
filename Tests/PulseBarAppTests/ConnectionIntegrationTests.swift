import Foundation
import XCTest

@testable import PulseBarApp
@testable import PulseBarUI

final class ConnectionIntegrationTests: XCTestCase {
    @MainActor
    func testLoginReachesLiveTelemetryAndPersistsSession() async throws {
        let server = try await DashboardFixture(scenario: .live)
        let store = MemorySessionStore(username: "", token: nil)
        let model = MetricsViewModel(dashboard: DashboardClient(fixtureURL: server.url), sessionStore: store)
        defer {
            model.signOut()
            server.stop()
        }

        let connectionMessage = await model.testConnection()
        XCTAssertEqual(connectionMessage.tone, .success)
        XCTAssertTrue(connectionMessage.message.hasPrefix("Dashboard reachable over SSH"))
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
            let store = MemorySessionStore(username: "", token: nil)
            let model = MetricsViewModel(dashboard: DashboardClient(fixtureURL: server.url), sessionStore: store)
            defer {
                model.signOut()
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
        let model = MetricsViewModel(
            dashboard: DashboardClient(fixtureURL: server.url), sessionStore: MemorySessionStore(),
            endpoint: try DashboardEndpoint(port: 11000, sshHost: "lab"))
        defer {
            model.signOut()
            server.stop()
        }

        XCTAssertEqual(model.connectionHealth.state, .connecting)
        XCTAssertEqual(model.snapshot.menuBarTitle, "RAM -- GPU --")
        try await waitUntil { model.connectionHealth.state == .live }
        XCTAssertEqual(model.connectionHealth.state, .live)
        XCTAssertEqual(model.panelState(at: .now, historyWindow: .minute).headerTitle, "lab")
        XCTAssertNotNil(model.connectionHealth.lastSampleAt)
        XCTAssertNotEqual(model.snapshot.menuBarTitle, "RAM -- GPU --")

        model.refresh()
        XCTAssertEqual(model.connectionHealth.state, .reconnecting)
        XCTAssertEqual(model.panelState(at: .now, historyWindow: .minute).headerTitle, "lab")
        XCTAssertEqual(model.snapshot.gpu.note, "Reconnecting to lab…")
        XCTAssertEqual(model.snapshot.menuBarTitle, "RAM -- GPU --")
        try await waitUntil { model.connectionHealth.state == .live }
        XCTAssertNotEqual(model.snapshot.menuBarTitle, "RAM -- GPU --")
    }

    @MainActor
    func testNaturalStreamEndReconnectsAndResumesDelivery() async throws {
        let events = [10, 20].map { utilization in
            let payload =
                #"{"TelemetryForGPUs":[{"percentage_utilization":\#(utilization),"memory_total_in_mb":100,"memory_available_in_mb":50}]}"#
            return "event: gpu_telemetry\ndata: \(payload)\n\n"
        }.joined()
        let server = try await DashboardFixture(scenario: .live, firstStreamBody: Data(events.utf8))
        let model = MetricsViewModel(
            dashboard: DashboardClient(fixtureURL: server.url), sessionStore: MemorySessionStore())
        defer {
            model.signOut()
            server.stop()
        }

        try await waitUntil { model.connectionHealth.state == .reconnecting }
        XCTAssertEqual(model.telemetryPanelNote, "The dashboard closed the telemetry stream.")
        XCTAssertEqual(model.history.samples.map(\.gpuPercent), [10, 20])
        XCTAssertNil(model.snapshot.gpu.utilizationPercent)

        try await waitUntil { model.connectionHealth.state == .live }
        XCTAssertEqual(model.snapshot.gpu.utilizationPercent, 37)
        XCTAssertEqual(server.requests.filter { $0.path == "/api/v1/gpu_telemetry/stream" }.count, 2)
    }

    @MainActor
    func testSystemUpdateRestartClearsBothUpdateIndicatorsOnAutomaticReconnect() async throws {
        let server = try await DashboardFixture(scenario: .live)
        server.setUpdateAvailable(true)
        let model = MetricsViewModel(
            dashboard: DashboardClient(fixtureURL: server.url), sessionStore: MemorySessionStore(),
            endpoint: try DashboardEndpoint(port: 11000, sshHost: "lab"))
        defer {
            model.signOut()
            server.stop()
        }

        try await waitUntil { model.menuBarPresentation(display: .both).showsAvailableUpdate }
        XCTAssertEqual(model.panelState(at: .now, historyWindow: .minute).systemUpdateStatus, .available)
        server.disconnectTelemetry()
        try await waitUntil { model.connectionHealth.state == .reconnecting }
        let disconnected = model.menuBarPresentation(display: .both)
        XCTAssertEqual(disconnected.fallbackTitle, model.preferencesState(port: "11000", host: "lab").connectionTitle)
        XCTAssertFalse(disconnected.showsAvailableUpdate)
        XCTAssertEqual(model.panelState(at: .now, historyWindow: .minute).systemUpdateStatus, .staleAvailable)

        server.setUpdateAvailable(false)
        try await waitUntil { model.connectionHealth.state == .live && model.updateStatus == .upToDate }
        XCTAssertEqual(model.menuBarPresentation(display: .both).fallbackTitle, "RAM 50% GPU 37%")
        XCTAssertFalse(model.menuBarPresentation(display: .both).showsAvailableUpdate)
        XCTAssertEqual(model.panelState(at: .now, historyWindow: .minute).systemUpdateStatus, .upToDate)
        XCTAssertEqual(server.requests.filter { $0.path == "/api/v1/updates/available" }.count, 2)
    }

    @MainActor
    func testRepeatedUnknownEventsShowInPanelUntilTelemetryResumes() async throws {
        let server = try await DashboardFixture(scenario: .renamedEventsThenLive)
        let model = MetricsViewModel(
            dashboard: DashboardClient(fixtureURL: server.url), sessionStore: MemorySessionStore())
        defer {
            model.signOut()
            server.stop()
        }

        try await waitUntil { model.telemetryPanelNote?.contains("gpu_metrics_v2") == true }
        XCTAssertEqual(model.connectionHealth.state, .waiting)
        XCTAssertTrue(model.telemetryPanelNote?.contains("gpu_telemetry") == true)
        XCTAssertTrue(model.history.samples.isEmpty)
        try await waitUntil { model.connectionHealth.state == .live }
        XCTAssertNil(model.telemetryPanelNote)
        XCTAssertEqual(server.requests.filter { $0.path == "/api/v1/gpu_telemetry/stream" }.count, 1)
    }

    @MainActor
    func testCarriageReturnLineEndingsDeliverTelemetry() async throws {
        for scenario in [DashboardFixture.Scenario.carriageReturnOnly, .carriageReturnLineFeed] {
            let server = try await DashboardFixture(scenario: scenario)
            let model = MetricsViewModel(
                dashboard: DashboardClient(fixtureURL: server.url), sessionStore: MemorySessionStore())
            defer {
                model.signOut()
                server.stop()
            }
            try await waitUntil { model.connectionHealth.state == .live }
            XCTAssertEqual(model.snapshot.menuBarTitle, "RAM 50% GPU 37%", scenario.rawValue)
        }
    }

    @MainActor
    func testMalformedEventDoesNotPreventFollowingSample() async throws {
        let server = try await DashboardFixture(scenario: .malformedThenLive)
        let model = MetricsViewModel(
            dashboard: DashboardClient(fixtureURL: server.url), sessionStore: MemorySessionStore())
        defer {
            model.signOut()
            server.stop()
        }

        try await waitUntil { model.connectionHealth.state == .live }
        XCTAssertEqual(model.snapshot.menuBarTitle, "RAM 50% GPU 37%")
    }

    @MainActor
    func testHeartbeatOnlyStreamClearsReadingsAndRestartsWhenStale() async throws {
        let server = try await DashboardFixture(scenario: .heartbeatOnly)
        let model = MetricsViewModel(
            dashboard: DashboardClient(fixtureURL: server.url), sessionStore: MemorySessionStore())
        defer {
            model.signOut()
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
        let store = MemorySessionStore()
        let model = MetricsViewModel(dashboard: DashboardClient(fixtureURL: server.url), sessionStore: store)
        defer {
            model.signOut()
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
        let model = MetricsViewModel(
            dashboard: DashboardClient(fixtureURL: server.url), sessionStore: MemorySessionStore(),
            endpoint: try DashboardEndpoint(port: 11000, sshHost: "lab"))
        defer {
            model.signOut()
            server.stop()
        }

        try await waitUntil { model.connectionHealth.state == .live }
        model.signOut()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.connectionHealth.state, .signedOut)
        let signedOutPanel = model.panelState(at: .now, historyWindow: .minute)
        XCTAssertEqual(signedOutPanel.headerTitle, "PulseBar")
        XCTAssertTrue(signedOutPanel.needsSignIn)
        XCTAssertEqual(signedOutPanel.signInPrompt, "Sign in to DGX Dashboard to view telemetry.")
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(model.connectionHealth.lastSampleAt)
        XCTAssertEqual(model.snapshot.menuBarTitle, "RAM -- GPU --")
    }

    @MainActor
    func testSwitchingBetweenTwoDevicesKeepsBothStreamsAndHistoriesLive() async throws {
        let first = try DashboardEndpoint(port: 11000, sshHost: "desk")
        let second = try DashboardEndpoint(port: 11000, sshHost: "lab")
        let deskServer = try await DashboardFixture(scenario: .live, token: "desk-token", gpuUtilization: 11)
        defer { deskServer.stop() }
        let labServer = try await DashboardFixture(scenario: .live, token: "lab-token", gpuUtilization: 79)
        defer { labServer.stop() }
        deskServer.setUpdateAvailable(true)
        let deskStore = MemorySessionStore(token: "desk-token")
        let labStore = MemorySessionStore(username: "", token: nil)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(first.sshHost, forKey: DashboardEndpoint.hostPreferenceKey)
        defaults.set(first.port, forKey: DashboardEndpoint.preferenceKey)

        let sessions = DeviceSessions(defaults: defaults) { endpoint in
            MetricsViewModel(
                dashboard: DashboardClient(fixtureURL: endpoint == first ? deskServer.url : labServer.url),
                sessionStore: endpoint == first ? deskStore : labStore, endpoint: endpoint,
                reconnectPauseStore: DashboardReconnectPauseStore(defaults: defaults))
        }
        let desk = sessions.displayed
        defer { desk.signOut() }
        try await waitUntil { desk.connectionHealth.state == .live }

        let setup = DGXConnectionSetup(probe: { _ in try await DashboardClient(fixtureURL: labServer.url).checkConnection() })
        let verification = try XCTUnwrap(setup.connect(second, onConnected: sessions.didVerify))
        await verification.value
        let lab = sessions.managed
        XCTAssertEqual(lab.endpoint, second)
        XCTAssertTrue(sessions.displayed === desk)
        defer { lab.signOut() }
        lab.username = "demo"
        lab.password = "demo"
        let login = try XCTUnwrap(lab.signIn(portText: "11000", sshHost: "lab"))
        await login.value
        try await waitUntil { lab.connectionHealth.state == .live && lab.updateStatus == .upToDate && desk.updateStatus == .available }

        for (alias, gpu, update) in [("lab", 79.0, false), ("desk", 11.0, true)] {
            let previousDesk = desk.history.samples.count
            let previousLab = lab.history.samples.count
            sessions.display(alias)
            sessions.manage(alias == "lab" ? "desk" : "lab")
            try await waitUntil { desk.history.samples.count > previousDesk && lab.history.samples.count > previousLab }
            let panel = sessions.panelState(at: .now, historyWindow: .minute)
            XCTAssertEqual(panel.selectedDevice, alias)
            XCTAssertEqual(panel.headerTitle, alias)
            XCTAssertEqual(panel.devices.map(\.alias), ["desk", "lab"])
            XCTAssertTrue(panel.devices.allSatisfy { $0.tone == .success })
            XCTAssertEqual(Set(panel.points.map(\.gpuPercent)), [gpu])
            XCTAssertEqual(panel.systemUpdateStatus, update ? .available : .upToDate)
            let menu = sessions.displayed.menuBarPresentation(display: .both)
            XCTAssertEqual(menu.snapshot.gpu.utilizationPercent, gpu)
            XCTAssertEqual(menu.showsAvailableUpdate, update)
        }

        XCTAssertEqual(sessions.devices.map(\.alias), ["desk", "lab"])
        for (server, token) in [(deskServer, "desk-token"), (labServer, "lab-token")] {
            let streams = server.requests.filter { $0.path.hasSuffix("/stream") }
            XCTAssertEqual(streams.count, 1)
            XCTAssertEqual(streams.first?.headers["authorization"], "Bearer " + token)
        }
        sessions.display("lab")
        labServer.disconnectTelemetry()
        try await waitUntil { lab.connectionHealth.state == .reconnecting }
        XCTAssertEqual(sessions.devices.map(\.tone), [.success, .warning])
        XCTAssertEqual(desk.connectionHealth.state, .live)
        let previousDesk = desk.history.samples.count
        lab.signOut()
        XCTAssertTrue(sessions.panelState(at: .now, historyWindow: .minute).needsSignIn)
        XCTAssertEqual(sessions.devices.map(\.tone), [.success, .neutral])
        XCTAssertNil(labStore.token)
        XCTAssertEqual(deskStore.token, "desk-token")
        sessions.display("desk")
        try await waitUntil { desk.history.samples.count > previousDesk }
        XCTAssertTrue(lab.history.samples.isEmpty)
        XCTAssertEqual(deskServer.requests.filter { $0.path.hasSuffix("/stream") }.count, 1)
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
final class MemorySessionStore: DashboardSessionStoring {
    private var username: String
    private(set) var token: String?
    init(username: String = "demo", token: String? = "simulator-token") {
        self.username = username
        self.token = token
    }
    func loadUsername() -> String { username }
    func saveUsername(_ username: String) { self.username = username }
    func clearUsername() { username = "" }
    func loadToken(allowInteraction: Bool) -> String? { token }
    func saveToken(_ token: String) { self.token = token }
    func clearToken(allowInteraction: Bool) { token = nil }
}

private enum FixtureError: Error {
    case timeout
}
