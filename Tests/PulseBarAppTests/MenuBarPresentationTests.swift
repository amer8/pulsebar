import PulseBarUI
import SwiftUI
import XCTest

@testable import PulseBarApp

final class MenuBarPresentationTests: XCTestCase {
    private let live = MetricsSnapshot.live(TelemetrySample(gpuUtilizationPercent: 37, memoryTotalMB: 100, memoryAvailableMB: 50))

    func testNonLiveStatesReplaceReadingsInEveryDisplayMode() {
        for display in MenuBarDisplay.allCases {
            for state: TelemetryConnectionHealth.State in [
                .signedOut, .signingIn, .connecting, .waiting, .stale, .reconnecting, .paused, .expired,
            ] {
                let presentation = MenuBarPresentation(state: state, snapshot: live, display: display)
                XCTAssertNotNil(presentation.connectionSymbol)
                XCTAssertEqual(presentation.fallbackTitle, state.rawValue)
                XCTAssertFalse(presentation.accessibilityLabel.contains("%"))
            }
            let paused = MenuBarPresentation(state: .paused, snapshot: live, display: display)
            XCTAssertTrue(paused.accessibilityLabel.contains("Open PulseBar to reconnect"))
            let expired = MenuBarPresentation(state: .expired, snapshot: live, display: display)
            XCTAssertTrue(expired.accessibilityLabel.contains("Open PulseBar to sign in"))
        }
    }

    func testLiveReadingsAndUpdateBadgeRespectSelectedDisplay() {
        for (display, readings): (MenuBarDisplay, String) in [
            (.both, "RAM 50% GPU 37%"), (.memory, "RAM 50%"), (.gpu, "GPU 37%"), (.icon, "PulseBar"),
        ] {
            var presentation = MenuBarPresentation(state: .live, snapshot: live, display: display)
            XCTAssertNil(presentation.connectionSymbol)
            XCTAssertEqual(presentation.accessibilityLabel, "\(readings). Connected.")
            XCTAssertEqual(presentation.fallbackTitle, readings)
            presentation.showsAvailableUpdate = true
            XCTAssertEqual(presentation.fallbackTitle, "\(readings) ↓")
            XCTAssertTrue(presentation.accessibilityLabel.contains("DGX system update available"))
        }
    }

    @MainActor
    func testRenderedReconnectingItemNeverContainsPreviousReadings() throws {
        func pixels(_ state: TelemetryConnectionHealth.State, _ snapshot: MetricsSnapshot, _ display: MenuBarDisplay) throws -> Data {
            let label = MenuBarLabelView(presentation: MenuBarPresentation(state: state, snapshot: snapshot, display: display))
            let image = try XCTUnwrap(ImageRenderer(content: label).cgImage)
            return try XCTUnwrap(NSBitmapImageRep(cgImage: image).tiffRepresentation)
        }
        for display in MenuBarDisplay.allCases {
            let reconnecting = try pixels(.reconnecting, live, display)
            XCTAssertEqual(reconnecting, try pixels(.reconnecting, .signedOut(), display))
            XCTAssertNotEqual(reconnecting, try pixels(.live, live, display))
        }
    }
}
