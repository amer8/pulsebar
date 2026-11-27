import Foundation
import PulseBarUI
import XCTest

@testable import PulseBarApp

@MainActor
final class UpdateAvailabilityTests: XCTestCase {
    func testSuccessFailureAndRetryRecovery() async throws {
        let dashboard = UpdateDashboard(
            initialSample: TelemetrySample(gpuUtilizationPercent: 40, memoryTotalMB: 100, memoryAvailableMB: 50))
        let sleep = UpdateSleep()
        let store = UpdateSessionStore()
        let model = makeModel(dashboard, sleep, store)
        defer { model.signOut() }

        XCTAssertEqual(model.updateStatus, .unknown)
        try await waitUntil { await dashboard.tokens.count == 1 }
        await dashboard.complete(0, .success(UpdateAvailability(available: true)))
        try await waitUntil { await sleep.durations.count == 1 }
        try await waitUntil { model.connectionHealth.state == .live }
        XCTAssertEqual(model.updateStatus, .available)
        XCTAssertTrue(model.menuBarPresentation(display: .both).showsAvailableUpdate)
        XCTAssertEqual(model.panelState(at: .now, historyWindow: .minute).systemUpdateStatus, .available)
        let firstDelay = await sleep.durations[0]
        XCTAssertEqual(firstDelay, .seconds(30))

        await sleep.resume(0)
        try await waitUntil { await dashboard.tokens.count == 2 }
        await dashboard.complete(1, .failure(URLError(.networkConnectionLost)))
        try await waitUntil { await sleep.durations.count == 2 }
        XCTAssertEqual(model.updateStatus, .staleAvailable)
        XCTAssertFalse(model.menuBarPresentation(display: .both).showsAvailableUpdate)
        XCTAssertEqual(model.panelState(at: .now, historyWindow: .minute).systemUpdateStatus, .staleAvailable)
        XCTAssertTrue(model.isSignedIn)
        let retryDelay = await sleep.durations[1]
        XCTAssertEqual(retryDelay, .seconds(30))

        await sleep.resume(1)
        try await waitUntil { await dashboard.tokens.count == 3 }
        await dashboard.complete(2, .success(UpdateAvailability(available: false)))
        try await waitUntil { await sleep.durations.count == 3 }
        XCTAssertEqual(model.updateStatus, .upToDate)
        XCTAssertFalse(model.menuBarPresentation(display: .both).showsAvailableUpdate)
        XCTAssertEqual(model.panelState(at: .now, historyWindow: .minute).systemUpdateStatus, .upToDate)
        let recoveredDelay = await sleep.durations[2]
        XCTAssertEqual(recoveredDelay, .seconds(3600))
        await sleep.resume(2)
        try await waitUntil { await dashboard.tokens.count == 4 }
        await dashboard.complete(3, .failure(URLError(.timedOut)))
        try await waitUntil { await sleep.durations.count == 4 }
        XCTAssertEqual(model.updateStatus, .staleUpToDate)
        await sleep.resume(3)
    }

    func testStaleStreamRecoveryRejectsLatePreUpdateResult() async throws {
        let dashboard = UpdateDashboard(
            initialSample: TelemetrySample(gpuUtilizationPercent: 40, memoryTotalMB: 100, memoryAvailableMB: 50))
        let sleep = UpdateSleep()
        let model = makeModel(dashboard, sleep, UpdateSessionStore())
        defer { model.signOut() }

        try await waitUntil { model.connectionHealth.state == .live }
        try await waitUntil { await dashboard.tokens.count == 1 }
        await dashboard.complete(0, .success(UpdateAvailability(available: true)))
        try await waitUntil { await sleep.durations.count == 1 }
        await sleep.resume(0)
        try await waitUntil { await dashboard.tokens.count == 2 }
        let oldCheck = try XCTUnwrap(model.updateAvailabilityTask)

        model.checkFreshness(at: .now.addingTimeInterval(31))
        XCTAssertEqual(model.connectionHealth.state, .stale)
        XCTAssertEqual(model.panelState(at: .now, historyWindow: .minute).systemUpdateStatus, .staleAvailable)
        XCTAssertFalse(model.menuBarPresentation(display: .both).showsAvailableUpdate)
        try await waitUntil { await dashboard.tokens.count == 3 }
        XCTAssertEqual(model.connectionHealth.state, .live)
        XCTAssertFalse(model.menuBarPresentation(display: .both).showsAvailableUpdate)

        await dashboard.complete(2, .success(UpdateAvailability(available: false)))
        try await waitUntil { await sleep.durations.count == 2 }
        await dashboard.complete(1, .success(UpdateAvailability(available: true)))
        await oldCheck.value
        XCTAssertFalse(model.menuBarPresentation(display: .both).showsAvailableUpdate)
        XCTAssertEqual(model.panelState(at: .now, historyWindow: .minute).systemUpdateStatus, .upToDate)
        model.signOut()
        await sleep.resume(1)
    }

    func testInitialFailureIsUnknownAndRetries() async throws {
        let dashboard = UpdateDashboard()
        let sleep = UpdateSleep()
        let model = makeModel(dashboard, sleep, UpdateSessionStore())
        defer { model.signOut() }
        try await waitUntil { await dashboard.tokens.count == 1 }
        await dashboard.complete(0, .failure(URLError(.cannotConnectToHost)))
        try await waitUntil { await sleep.durations.count == 1 }
        XCTAssertEqual(model.updateStatus, .unknown)
        let delay = await sleep.durations[0]
        XCTAssertEqual(delay, .seconds(30))
        await sleep.resume(0)
        try await waitUntil { await dashboard.tokens.count == 2 }
        await dashboard.complete(1, .success(UpdateAvailability(available: true)))
        try await waitUntil { await sleep.durations.count == 2 }
        XCTAssertEqual(model.updateStatus, .available)
        await sleep.resume(1)
    }

    func testReleasingModelCancelsOpenStreamAndPendingUpdateRequest() async throws {
        let dashboard = UpdateDashboard()
        var model: MetricsViewModel? = makeModel(dashboard, UpdateSleep(), UpdateSessionStore())
        let retainedModel = { [weak model] in model }
        defer { retainedModel()?.signOut() }
        let updateTask = try XCTUnwrap(model?.updateAvailabilityTask)
        try await waitUntil { model?.connectionHealth.state == .waiting }
        try await waitUntil { await dashboard.tokens.count == 1 }

        model = nil
        XCTAssertNil(retainedModel())
        XCTAssertTrue(updateTask.isCancelled)
        await dashboard.complete(0, .failure(CancellationError()))
        await updateTask.value
        try await waitUntil { await dashboard.streamCancelled }
    }

    func testUnauthorizedExpiresSessionAndClearsSavedCredentials() async throws {
        let dashboard = UpdateDashboard(
            initialSample: TelemetrySample(gpuUtilizationPercent: 40, memoryTotalMB: 100, memoryAvailableMB: 50))
        let sleep = UpdateSleep()
        let store = UpdateSessionStore()
        let model = makeModel(dashboard, sleep, store)
        try await waitUntil { await dashboard.tokens.count == 1 }
        try await waitUntil { !model.history.samples.isEmpty }
        await dashboard.complete(0, .failure(DashboardError.unauthorized))
        try await waitUntil { !model.isSignedIn }
        XCTAssertTrue(model.history.samples.isEmpty)
        XCTAssertNil(store.token)
        XCTAssertEqual(store.deleteInteractions, [false])
        XCTAssertEqual(store.username, "")
        XCTAssertEqual(model.updateStatus, .unknown)
        XCTAssertEqual(model.snapshot.gpu.note, "Your dashboard session expired. Sign in again.")
        let panel = model.panelState(at: .now, historyWindow: .fiveMinutes)
        XCTAssertTrue(panel.points.isEmpty)
        XCTAssertNil(panel.lastSampleAt)
        XCTAssertNil(panel.memoryPercent)
        XCTAssertNil(panel.gpuPercent)
        XCTAssertEqual(panel.systemUpdateStatus, .hidden)
        XCTAssertEqual(panel.recoveryAction, .signIn)
        XCTAssertTrue(panel.needsSignIn)
        XCTAssertFalse(panel.canReconnect)
        let delays = await sleep.durations
        XCTAssertTrue(delays.isEmpty)
    }

    func testOldResponsesCannotChangeNewSessionEvenWithSameToken() async throws {
        let dashboard = UpdateDashboard()
        let sleep = UpdateSleep()
        let store = UpdateSessionStore()
        let model = makeModel(dashboard, sleep, store)
        defer { model.signOut() }
        try await waitUntil { await dashboard.tokens.count == 1 }
        let oldTask = try XCTUnwrap(model.updateAvailabilityTask)
        model.signOut()
        model.username = "new-user"
        model.password = "password"
        let signIn = try XCTUnwrap(model.signIn())
        await signIn.value
        try await waitUntil { await dashboard.tokens.count == 2 }
        await dashboard.complete(1, .success(UpdateAvailability(available: true)))
        try await waitUntil { await sleep.durations.count == 1 }
        await dashboard.complete(0, .failure(DashboardError.unauthorized))
        // The old request ignores cancellation; its completion must not expire the new session.
        await oldTask.value
        XCTAssertTrue(model.isSignedIn)
        XCTAssertEqual(model.updateStatus, .available)
        XCTAssertEqual(store.username, "new-user")
        await sleep.resume(0)
    }

    func testReconnectMarksResultStaleAndIgnoresSupersededResponse() async throws {
        let dashboard = UpdateDashboard()
        let sleep = UpdateSleep()
        let model = makeModel(dashboard, sleep, UpdateSessionStore())
        defer { model.signOut() }
        try await waitUntil { await dashboard.tokens.count == 1 }
        await dashboard.complete(0, .success(UpdateAvailability(available: false)))
        try await waitUntil { await sleep.durations.count == 1 }
        await sleep.resume(0)
        try await waitUntil { await dashboard.tokens.count == 2 }
        let oldTask = try XCTUnwrap(model.updateAvailabilityTask)
        model.refresh()
        XCTAssertEqual(model.updateStatus, .staleUpToDate)
        try await waitUntil { await dashboard.tokens.count == 3 }
        await dashboard.complete(1, .success(UpdateAvailability(available: true)))
        await oldTask.value
        XCTAssertEqual(model.updateStatus, .staleUpToDate)
        await dashboard.complete(2, .success(UpdateAvailability(available: false)))
        try await waitUntil { await sleep.durations.count == 2 }
        XCTAssertEqual(model.updateStatus, .upToDate)
        await sleep.resume(1)
    }

    private func makeModel(_ dashboard: UpdateDashboard, _ sleep: UpdateSleep, _ store: UpdateSessionStore) -> MetricsViewModel {
        let suite = "PulseBar.UpdateAvailabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return MetricsViewModel(
            dashboard: dashboard, sessionStore: store, reconnectPauseStore: DashboardReconnectPauseStore(defaults: defaults),
            updateSleep: { try await sleep.wait($0) })
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw UpdateTestError.timeout }
            await Task.yield()
        }
    }
}

private enum UpdateTestError: Error { case timeout }

private actor UpdateDashboard: DashboardServing {
    let initialSample: TelemetrySample?
    init(initialSample: TelemetrySample? = nil) { self.initialSample = initialSample }
    private(set) var tokens: [String] = []
    private(set) var streamCancelled = false
    private var pending: [Int: CheckedContinuation<UpdateAvailability, Error>] = [:]
    func login(username: String, password: String) async throws -> String { "token" }
    func checkConnection() async throws -> Bool { true }
    func updateAvailability(token: String) async throws -> UpdateAvailability {
        let index = tokens.count
        tokens.append(token)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func complete(_ index: Int, _ result: Result<UpdateAvailability, Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }
    func consumeTelemetryStream(
        token: String, onLog: @escaping @Sendable (String) -> Void,
        onStatus: @escaping @Sendable (TelemetryStreamStatus) async -> Void, onSample: @escaping @Sendable (TelemetrySample) async -> Void
    ) async throws {
        await onStatus(.connected)
        if let initialSample { await onSample(initialSample) }
        defer { streamCancelled = Task.isCancelled }
        try await Task.sleep(for: .seconds(3600))
    }
}

private actor UpdateSleep {
    private(set) var durations: [Duration] = []
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    func wait(_ duration: Duration) async throws {
        let index = durations.count
        durations.append(duration)
        await withCheckedContinuation { pending[index] = $0 }
        try Task.checkCancellation()
    }
    func resume(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
}

@MainActor
private final class UpdateSessionStore: DashboardSessionStoring {
    var username = "user"
    var token: String? = "token"
    var deleteInteractions: [Bool] = []
    func loadUsername() -> String { username }
    func saveUsername(_ username: String) { self.username = username }
    func clearUsername() { username = "" }
    func loadToken(allowInteraction: Bool) -> String? { token }
    func saveToken(_ token: String) { self.token = token }
    func clearToken(allowInteraction: Bool) {
        deleteInteractions.append(allowInteraction)
        token = nil
    }
}
