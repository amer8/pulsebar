import XCTest

@testable import PulseBarApp

final class TelemetryHistoryTests: XCTestCase {
    private let sample = TelemetrySample(gpuUtilizationPercent: 37, memoryTotalMB: 65_536, memoryAvailableMB: 16_384)

    @MainActor
    func testDemoPublishesHealthySamplesWithoutTouchingSavedCredentials() async throws {
        let store = DemoSessionStore()
        let model = MetricsViewModel(sessionStore: store, demo: true)
        defer { model.signOut() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.history.samples.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.history.samples.isEmpty)
        XCTAssertEqual(model.connectionHealth.state, .live)
        XCTAssertNotNil(model.connectionHealth.lastSampleAt)
        XCTAssertFalse(model.isSignedIn)
        XCTAssertEqual(store.reads, 0)
        XCTAssertEqual(store.writes, 0)
    }

    func testHistoryEvictsOldAndExcessSamples() {
        var history = TelemetryHistory(maximumSamples: 2, maximumAge: 10)
        for time in [0.0, 1, 2] { history.append(sample, at: Date(timeIntervalSince1970: time)) }
        XCTAssertEqual(history.samples.map(\.timestamp), [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2)])
        history.append(sample, at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples[0].freeGiB, 16)
        XCTAssertEqual(history.samples[0].memoryPercent, 75)
    }

    func testTimeWindowsAndGaps() {
        var history = TelemetryHistory()
        history.append(sample, at: Date(timeIntervalSince1970: 0))
        history.markGap()
        history.append(sample, at: Date(timeIntervalSince1970: 100))
        XCTAssertNotEqual(history.samples[0].segment, history.samples[1].segment)
        XCTAssertEqual(history.points(in: .minute, at: Date(timeIntervalSince1970: 100)).count, 1)
        XCTAssertEqual(history.points(in: .fiveMinutes, at: Date(timeIntervalSince1970: 100)).count, 2)
        XCTAssertEqual(history.points(in: .minute, at: Date(timeIntervalSince1970: 500)).count, 0)
    }

    func testClockReversalAndDuplicateTimestamps() {
        var history = TelemetryHistory()
        history.append(sample, at: Date(timeIntervalSince1970: 10))
        history.append(sample, at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(history.samples.count, 1)
        history.append(sample, at: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples[0].timestamp, Date(timeIntervalSince1970: 1))
    }
}

@MainActor
private final class DemoSessionStore: DashboardSessionStoring {
    private(set) var reads = 0
    private(set) var writes = 0
    func loadUsername() -> String {
        reads += 1
        return "saved-user"
    }
    func loadToken() -> String? {
        reads += 1
        return "saved-token"
    }
    func saveUsername(_ username: String) { writes += 1 }
    func clearUsername() { writes += 1 }
    func saveToken(_ token: String) { writes += 1 }
    func clearToken() { writes += 1 }
}
