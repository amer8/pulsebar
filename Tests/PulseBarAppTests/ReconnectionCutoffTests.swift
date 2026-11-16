import AppKit
import XCTest

@testable import PulseBarApp

@MainActor
final class ReconnectionCutoffTests: XCTestCase {
    func testFailuresPauseAllPollingUntilManualReconnect() async throws {
        let dashboard = CutoffDashboard(mode: .failure)
        let model = MetricsViewModel(
            dashboard: dashboard, sessionStore: CutoffSessionStore(), reconnectPauseStore: makePauseStore(),
            retrySleep: { _ in await Task.yield() })
        defer { model.signOut() }

        try await waitUntil { model.connectionHealth.state == .paused }
        let attemptsAtCutoff = await dashboard.streamAttempts
        let updatesAtCutoff = await dashboard.updateAttempts
        XCTAssertEqual(attemptsAtCutoff, 5)
        XCTAssertTrue(model.isSignedIn)
        XCTAssertTrue(model.snapshot.gpu.note?.contains("Reconnect") == true)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        model.checkFreshness(at: .now.addingTimeInterval(60))
        try await Task.sleep(for: .milliseconds(100))
        let attemptsAfterWake = await dashboard.streamAttempts
        let updatesAfterWake = await dashboard.updateAttempts
        XCTAssertEqual(attemptsAfterWake, attemptsAtCutoff)
        XCTAssertEqual(updatesAfterWake, updatesAtCutoff)
        XCTAssertEqual(model.connectionHealth.state, .paused)

        await dashboard.setMode(.healthy)
        model.refresh()
        try await waitUntil { model.connectionHealth.state == .live }
        let resumedAttempts = await dashboard.streamAttempts
        let resumedUpdates = await dashboard.updateAttempts
        XCTAssertEqual(resumedAttempts, attemptsAtCutoff + 1)
        XCTAssertGreaterThan(resumedUpdates, updatesAtCutoff)
    }

    func testRepeatedStaleStreamsReachCutoff() async throws {
        let dashboard = CutoffDashboard(mode: .waiting)
        let model = MetricsViewModel(dashboard: dashboard, sessionStore: CutoffSessionStore(), reconnectPauseStore: makePauseStore())
        defer { model.signOut() }

        for attempt in 1...5 {
            try await waitUntil { model.connectionHealth.state == .waiting }
            model.checkFreshness(at: .now.addingTimeInterval(31))
            if attempt < 5 { XCTAssertNotEqual(model.connectionHealth.state, .paused) }
        }
        XCTAssertEqual(model.connectionHealth.state, .paused)
        let attempts = await dashboard.streamAttempts
        XCTAssertEqual(attempts, 5)
    }

    func testValidSampleResetsFailureStreak() async throws {
        let dashboard = CutoffDashboard(mode: .waiting)
        let model = MetricsViewModel(dashboard: dashboard, sessionStore: CutoffSessionStore(), reconnectPauseStore: makePauseStore())
        defer { model.signOut() }

        for _ in 0..<4 {
            try await waitUntil { model.connectionHealth.state == .waiting }
            model.checkFreshness(at: .now.addingTimeInterval(31))
        }
        try await waitUntil { model.connectionHealth.state == .waiting }
        await dashboard.sendSample()
        try await waitUntil { model.connectionHealth.state == .live }
        for _ in 0..<4 {
            model.checkFreshness(at: .now.addingTimeInterval(31))
            XCTAssertNotEqual(model.connectionHealth.state, .paused)
            try await waitUntil { model.connectionHealth.state == .waiting }
        }
        model.checkFreshness(at: .now.addingTimeInterval(31))
        XCTAssertEqual(model.connectionHealth.state, .paused)
    }

    func testPausePersistsAcrossModelRestartUntilReconnect() async throws {
        let suite = "PulseBar.ReconnectionCutoffTests.\(UUID().uuidString)"
        let pauseStore = makePauseStore(suite: suite)
        let endpoint = try DashboardEndpoint(port: 11000)
        let firstDashboard = CutoffDashboard(mode: .failure)
        var first: MetricsViewModel? = MetricsViewModel(
            dashboard: firstDashboard, sessionStore: CutoffSessionStore(), endpoint: endpoint,
            reconnectPauseStore: pauseStore, retrySleep: { _ in await Task.yield() })
        try await waitUntil { first?.connectionHealth.state == .paused }
        XCTAssertTrue(pauseStore.isPaused(for: endpoint))
        first = nil

        let nextDashboard = CutoffDashboard(mode: .healthy)
        let restoredStore = DashboardReconnectPauseStore(defaults: UserDefaults(suiteName: suite)!)
        let restored = MetricsViewModel(
            dashboard: nextDashboard, sessionStore: CutoffSessionStore(), endpoint: endpoint, reconnectPauseStore: restoredStore)
        defer { restored.signOut() }
        XCTAssertEqual(restored.connectionHealth.state, .paused)
        XCTAssertTrue(restored.isSignedIn)
        try await Task.sleep(for: .milliseconds(100))
        let streamsBeforeReconnect = await nextDashboard.streamAttempts
        let updatesBeforeReconnect = await nextDashboard.updateAttempts
        XCTAssertEqual(streamsBeforeReconnect, 0)
        XCTAssertEqual(updatesBeforeReconnect, 0)

        restored.refresh()
        try await waitUntil { restored.connectionHealth.state == .live }
        XCTAssertFalse(restoredStore.isPaused(for: endpoint))
        let thirdDashboard = CutoffDashboard(mode: .healthy)
        let third = MetricsViewModel(
            dashboard: thirdDashboard, sessionStore: CutoffSessionStore(), endpoint: endpoint, reconnectPauseStore: restoredStore)
        defer { third.signOut() }
        try await waitUntil { third.connectionHealth.state == .live }
    }

    func testPauseIsIsolatedByEndpointAndSurvivesSignOutAndSignIn() async throws {
        let pauseStore = makePauseStore()
        let pausedEndpoint = try DashboardEndpoint(port: 12000)
        let otherEndpoint = try DashboardEndpoint(port: 12001)
        pauseStore.setPaused(true, for: pausedEndpoint)
        let pausedDashboard = CutoffDashboard(mode: .healthy)
        let sessionStore = CutoffSessionStore()
        let paused = MetricsViewModel(
            dashboard: pausedDashboard, sessionStore: sessionStore, endpoint: pausedEndpoint, reconnectPauseStore: pauseStore)
        XCTAssertEqual(paused.connectionHealth.state, .paused)
        paused.signOut()
        XCTAssertTrue(pauseStore.isPaused(for: pausedEndpoint))
        paused.username = "test"
        paused.password = "password"
        let signIn = try XCTUnwrap(paused.signIn())
        await signIn.value
        XCTAssertEqual(paused.connectionHealth.state, .paused)
        let pausedAttempts = await pausedDashboard.streamAttempts
        XCTAssertEqual(pausedAttempts, 0)

        let otherDashboard = CutoffDashboard(mode: .healthy)
        let other = MetricsViewModel(
            dashboard: otherDashboard, sessionStore: CutoffSessionStore(), endpoint: otherEndpoint, reconnectPauseStore: pauseStore)
        defer {
            paused.signOut()
            other.signOut()
        }
        try await waitUntil { other.connectionHealth.state == .live }
        XCTAssertTrue(pauseStore.isPaused(for: pausedEndpoint))
        XCTAssertFalse(pauseStore.isPaused(for: otherEndpoint))
        paused.refresh()
        try await waitUntil { paused.connectionHealth.state == .live }
        XCTAssertFalse(pauseStore.isPaused(for: pausedEndpoint))
    }

    func testRecoveredSessionKeepsPersistedPause() async throws {
        let pauseStore = makePauseStore()
        let endpoint = try DashboardEndpoint(port: 12002)
        pauseStore.setPaused(true, for: endpoint)
        let store = CutoffSessionStore()
        store.clearToken()
        let dashboard = CutoffDashboard(mode: .healthy)
        let model = MetricsViewModel(dashboard: dashboard, sessionStore: store, endpoint: endpoint, reconnectPauseStore: pauseStore)
        defer { model.signOut() }
        store.saveToken("token")
        model.retrySavedSession()
        XCTAssertEqual(model.connectionHealth.state, .paused)
        let attempts = await dashboard.streamAttempts
        XCTAssertEqual(attempts, 0)
        model.refresh()
        try await waitUntil { model.connectionHealth.state == .live }
    }

    private func makePauseStore(suite: String = "PulseBar.ReconnectionCutoffTests.\(UUID().uuidString)") -> DashboardReconnectPauseStore {
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return DashboardReconnectPauseStore(defaults: defaults)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CutoffTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum CutoffTestError: Error { case timeout }

private actor CutoffDashboard: DashboardServing {
    enum Mode { case failure, waiting, healthy }
    private var mode: Mode
    private(set) var streamAttempts = 0
    private(set) var updateAttempts = 0
    private var onSample: (@Sendable (TelemetrySample) async -> Void)?

    init(mode: Mode) { self.mode = mode }
    func setMode(_ mode: Mode) { self.mode = mode }
    func sendSample() async {
        await onSample?(TelemetrySample(gpuUtilizationPercent: 20, memoryTotalMB: 1024, memoryAvailableMB: 512))
    }
    func login(username: String, password: String) async throws -> String { "token" }
    func checkConnection() async throws -> Bool { true }
    func updateAvailability(token: String) async throws -> UpdateAvailability {
        updateAttempts += 1
        throw URLError(.cannotConnectToHost)
    }
    func consumeTelemetryStream(
        token: String,
        onLog: @escaping @Sendable (String) -> Void,
        onConnected: @escaping @Sendable () async -> Void,
        onSample: @escaping @Sendable (TelemetrySample) async -> Void
    ) async throws {
        streamAttempts += 1
        if mode == .failure { throw URLError(.cannotConnectToHost) }
        self.onSample = onSample
        await onConnected()
        if mode == .healthy {
            await onSample(TelemetrySample(gpuUtilizationPercent: 20, memoryTotalMB: 1024, memoryAvailableMB: 512))
        }
        try await Task.sleep(for: .seconds(3600))
    }
}

@MainActor
private final class CutoffSessionStore: DashboardSessionStoring {
    func loadUsername() -> String { "test" }
    func saveUsername(_ username: String) {}
    func clearUsername() {}
    private var token: String? = "token"
    func loadToken() -> String? { token }
    func saveToken(_ token: String) { self.token = token }
    func clearToken() { token = nil }
}
