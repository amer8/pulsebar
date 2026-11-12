import Foundation
import PulseBarUI
import XCTest

final class TelemetryChartSelectionTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testFindsNearestPointAndPreservesItsMetrics() throws {
        let first = point(at: 0, ram: 20, gpu: 30)
        let second = point(at: 10, ram: 60, gpu: 75)
        let selected = try XCTUnwrap(
            TelemetryChartSelection.nearest(to: origin.addingTimeInterval(8), in: [first, second], within: 4))
        XCTAssertEqual(selected.timestamp, second.timestamp)
        XCTAssertEqual(selected.memoryPercent, 60)
        XCTAssertEqual(selected.gpuPercent, 75)
    }

    func testDoesNotSelectDistantPointInGap() {
        let points = [point(at: 0), point(at: 100)]
        XCTAssertNil(TelemetryChartSelection.nearest(to: origin.addingTimeInterval(50), in: points, within: 10))
        XCTAssertNotNil(TelemetryChartSelection.nearest(to: origin.addingTimeInterval(10), in: points, within: 10))
    }

    func testEmptyPointsAndInvalidToleranceDoNotSelect() {
        XCTAssertNil(TelemetryChartSelection.nearest(to: origin, in: [], within: 1))
        XCTAssertNil(TelemetryChartSelection.nearest(to: origin, in: [point(at: 0)], within: -1))
    }

    private func point(at seconds: TimeInterval, ram: Double = 0, gpu: Double = 0) -> TelemetryChartPoint {
        TelemetryChartPoint(timestamp: origin.addingTimeInterval(seconds), memoryPercent: ram, gpuPercent: gpu)
    }
}
