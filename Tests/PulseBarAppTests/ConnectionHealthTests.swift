import XCTest

@testable import PulseBarApp

final class ConnectionHealthTests: XCTestCase {
    func testFreshnessDeadlineAndRecovery() {
        var health = TelemetryConnectionHealth()
        let now = Date(timeIntervalSince1970: 100)
        health.beginConnection()
        health.connected(at: now)
        health.sampleReceived(at: now)
        XCTAssertFalse(health.markStale(at: now.addingTimeInterval(29)))
        XCTAssertTrue(health.markStale(at: now.addingTimeInterval(30)))
        XCTAssertEqual(health.state, .stale)
        XCTAssertFalse(health.markStale(at: now.addingTimeInterval(31)))
        health.connected(at: now.addingTimeInterval(32))
        XCTAssertFalse(health.markStale(at: now.addingTimeInterval(33)))
        health.sampleReceived(at: now.addingTimeInterval(34))
        XCTAssertEqual(health.state, .live)
    }
    func testHeartbeatOnlyConnectionBecomesStale() {
        var health = TelemetryConnectionHealth()
        let now = Date(timeIntervalSince1970: 100)
        health.connected(at: now)
        XCTAssertTrue(health.markStale(at: now.addingTimeInterval(30)))
        XCTAssertNil(health.lastSampleAt)
    }
    func testSignedOutAndExpiredSessionsHaveNoFreshSample() {
        var health = TelemetryConnectionHealth()
        XCTAssertFalse(health.markStale(at: .now))
        health.sampleReceived(at: .now)
        health.expire()
        XCTAssertNil(health.lastSampleAt)
        XCTAssertEqual(health.state, .expired)
        XCTAssertFalse(health.markStale(at: .now))
    }
    func testRetryBackoffIsBounded() {
        XCTAssertEqual(TelemetryConnectionHealth.retryDelay(failures: 1), .seconds(2))
        XCTAssertEqual(TelemetryConnectionHealth.retryDelay(failures: 3), .seconds(8))
        XCTAssertEqual(TelemetryConnectionHealth.retryDelay(failures: 100), .seconds(30))
    }
    func testInvalidWireSampleCannotCountAsFreshTelemetry() {
        let payload = Data(
            #"{"TelemetryForGPUs":[{"percentage_utilization":1e300,"memory_total_in_mb":65536,"memory_available_in_mb":32768}]}"#.utf8)
        XCTAssertThrowsError(try TelemetryParser.firstSample(from: payload))
    }
}
