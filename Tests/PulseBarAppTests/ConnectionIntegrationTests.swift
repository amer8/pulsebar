import Foundation
import XCTest

@testable import PulseBarApp

final class ConnectionIntegrationTests: XCTestCase {
    @MainActor
    func testMenuUsesLiveReadingsAfterConnectingAndRefreshing() async throws {
        let server = try DashboardFixture(scenario: "live")
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
        let server = try DashboardFixture(scenario: "heartbeat-only")
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
        let server = try DashboardFixture(scenario: "unauthorized")
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
        let server = try DashboardFixture(scenario: "live")
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
    private var username = "demo"
    private(set) var token: String? = "simulator-token"
    func loadUsername() -> String { username }
    func saveUsername(_ username: String) { self.username = username }
    func clearUsername() { username = "" }
    func loadToken() -> String? { token }
    func saveToken(_ token: String) { self.token = token }
    func clearToken() { token = nil }
}

private enum FixtureError: Error {
    case startup
    case timeout
}

private final class DashboardFixture {
    let url: URL
    private let process: Process

    init(scenario: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", root.appendingPathComponent("Scripts/dashboard-simulator.py").path, "--port", "0", "--scenario", scenario,
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        // The fixture prints its OS-assigned port immediately after binding.
        let data = output.fileHandleForReading.availableData
        let line = String(decoding: data, as: UTF8.self)
        guard let address = line.split(separator: " ").dropFirst().first, let url = URL(string: String(address)), url.port != nil else {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw FixtureError.startup
        }
        self.url = url
        self.process = process
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    deinit { stop() }
}
