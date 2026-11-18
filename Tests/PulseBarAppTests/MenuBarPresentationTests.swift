import PulseBarUI
import XCTest

@testable import PulseBarApp

final class MenuBarPresentationTests: XCTestCase {
    func testAttentionStatesAreVisibleAndAccessibleInEveryDisplayMode() {
        for display in MenuBarDisplay.allCases {
            let paused = MenuBarPresentation(state: .paused, snapshot: .signedOut(), display: display)
            XCTAssertTrue(paused.showsWarning, "\(display)")
            XCTAssertTrue(paused.fallbackTitle.hasPrefix("⚠"))
            XCTAssertTrue(paused.accessibilityLabel.contains("Reconnection paused"))
            XCTAssertTrue(paused.accessibilityLabel.contains("reconnect"))

            let expired = MenuBarPresentation(state: .expired, snapshot: .signedOut(), display: display)
            XCTAssertTrue(expired.showsWarning, "\(display)")
            XCTAssertTrue(expired.accessibilityLabel.contains("session expired"))
            XCTAssertTrue(expired.accessibilityLabel.contains("sign in"))
        }
    }

    func testOrdinaryStatesDoNotShowWarningAndDescribeSelectedReadings() {
        let snapshot = MetricsSnapshot.live(TelemetrySample(gpuUtilizationPercent: 37, memoryTotalMB: 100, memoryAvailableMB: 50))
        for state: TelemetryConnectionHealth.State in [.signedOut, .connecting, .waiting, .live, .stale, .reconnecting] {
            XCTAssertFalse(MenuBarPresentation(state: state, snapshot: snapshot).showsWarning, "\(state)")
        }
        XCTAssertEqual(MenuBarPresentation(state: .live, snapshot: snapshot, display: .icon).accessibilityLabel, "PulseBar. Connected.")
        XCTAssertEqual(MenuBarPresentation(state: .live, snapshot: snapshot, display: .memory).accessibilityLabel, "RAM 50%. Connected.")
        XCTAssertEqual(MenuBarPresentation(state: .live, snapshot: snapshot, display: .gpu).accessibilityLabel, "GPU 37%. Connected.")
    }
}
