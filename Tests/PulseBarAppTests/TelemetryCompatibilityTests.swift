import XCTest

@testable import PulseBarApp

final class TelemetryCompatibilityTests: XCTestCase {
    func testCurrentKiBPayloadIsNormalizedToExistingMemoryUnits() throws {
        let payload = Data(
            #"{"TelemetryForGPUs":[{"percentage_utilization":37,"memory_total_in_kib":134217728,"memory_available_in_kib":33554432}]}"#.utf8
        )
        let sample = try TelemetryParser.firstSample(from: payload)
        XCTAssertEqual(sample.gpuUtilizationPercent, 37)
        XCTAssertEqual(sample.memoryTotalMB, 131_072)
        XCTAssertEqual(sample.memoryAvailableMB, 32_768)
        XCTAssertEqual(MetricsSnapshot.live(sample).menuBarTitle, "RAM 75% GPU 37%")
    }

    func testKiBConversionPreservesFractionalValues() throws {
        let payload = Data(
            #"{"TelemetryForGPUs":[{"percentage_utilization":12.5,"memory_total_in_kib":134217728.5,"memory_available_in_kib":33554432.25}]}"#
                .utf8)
        let sample = try TelemetryParser.firstSample(from: payload)
        XCTAssertEqual(sample.memoryTotalMB, 134_217_728.5 / 1024, accuracy: 1e-9)
        XCTAssertEqual(sample.memoryAvailableMB, 33_554_432.25 / 1024, accuracy: 1e-9)
    }

    func testCurrentKiBFieldsTakePrecedenceWhenBothFormatsArePresent() throws {
        let payload = Data(
            #"{"TelemetryForGPUs":[{"percentage_utilization":37,"memory_total_in_kib":134217728,"memory_available_in_kib":33554432,"memory_total_in_mb":100,"memory_available_in_mb":50}]}"#
                .utf8)
        let sample = try TelemetryParser.firstSample(from: payload)
        XCTAssertEqual(sample.memoryTotalMB, 131_072)
        XCTAssertEqual(sample.memoryAvailableMB, 32_768)
    }

    func testMixedMemoryUnitsAreRejectedWithTheMissingFieldName() {
        let payload = Data(
            #"{"TelemetryForGPUs":[{"percentage_utilization":37,"memory_total_in_kib":134217728,"memory_available_in_mb":32768}]}"#.utf8)
        XCTAssertThrowsError(try TelemetryParser.firstSample(from: payload)) { error in
            XCTAssertTrue(error.localizedDescription.contains("memory_available_in_kib"), error.localizedDescription)
        }
    }

    func testMissingTelemetryEnvelopeProducesAnActionableError() {
        XCTAssertThrowsError(try TelemetryParser.firstSample(from: Data(#"{"GPUs":[]}"#.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("TelemetryForGPUs"), error.localizedDescription)
        }
    }
}
