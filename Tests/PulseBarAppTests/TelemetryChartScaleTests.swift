import PulseBarUI
import XCTest

final class TelemetryChartScaleTests: XCTestCase {
    func testEmptyAndIdleChartsHaveANonzeroScale() {
        XCTAssertEqual(TelemetryChartScale.upperBound(for: [], automatic: true), 5)
        XCTAssertEqual(TelemetryChartScale.upperBound(for: [0, 0, 0], automatic: true), 5)
    }

    func testAutoScaleContainsTheVisiblePeakAtFivePercentSteps() {
        XCTAssertEqual(TelemetryChartScale.upperBound(for: [2.2, 3.1, 2.3], automatic: true), 5)
        XCTAssertEqual(TelemetryChartScale.upperBound(for: [4.9, 5.1], automatic: true), 10)
        XCTAssertEqual(TelemetryChartScale.upperBound(for: [17, 84, 37], automatic: true), 85)
        XCTAssertEqual(TelemetryChartScale.upperBound(for: [99.9, 100], automatic: true), 100)
    }

    func testFullScalePreservesTheWholePercentageRange() {
        XCTAssertEqual(TelemetryChartScale.upperBound(for: [], automatic: false), 100)
        XCTAssertEqual(TelemetryChartScale.upperBound(for: [0, 2.3], automatic: false), 100)
        XCTAssertEqual(TelemetryChartScale.upperBound(for: [84], automatic: false), 100)
    }
}
