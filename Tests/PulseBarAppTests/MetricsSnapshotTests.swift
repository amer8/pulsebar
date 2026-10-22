import XCTest

@testable import PulseBarApp

final class MetricsSnapshotTests: XCTestCase {
    func testSignedOutSnapshotUsesFallbackDisplayValues() {
        let snapshot = MetricsSnapshot.signedOut(note: "Sign in required.")

        XCTAssertEqual(snapshot.menuBarTitle, "RAM -- GPU --")
        XCTAssertEqual(snapshot.memory.detailText, "Unavailable")
        XCTAssertEqual(snapshot.memory.menuDetailText, "--")
        XCTAssertEqual(snapshot.gpu.detailText, "Unavailable")
        XCTAssertEqual(snapshot.gpu.menuDetailText, "--")
        XCTAssertEqual(snapshot.gpu.summaryText, "GPU")
        XCTAssertEqual(snapshot.gpu.note, "Sign in required.")
    }

    func testConnectingSnapshotIncludesUsernameInStatusNote() {
        let snapshot = MetricsSnapshot.connecting(username: "alice")

        XCTAssertEqual(snapshot.memory.detailText, "Connecting…")
        XCTAssertEqual(snapshot.memory.menuDetailText, "--")
        XCTAssertEqual(snapshot.gpu.detailText, "Connecting…")
        XCTAssertEqual(snapshot.gpu.menuDetailText, "--")
        XCTAssertEqual(
            snapshot.gpu.note,
            "Connecting to local dashboard as alice…"
        )
    }

    func testTelemetryUnavailableSnapshotClearsLiveValues() {
        let liveSnapshot = MetricsSnapshot.live(
            TelemetrySample(
                gpuUtilizationPercent: 37,
                memoryTotalMB: 65_536,
                memoryAvailableMB: 16_384
            )
        )
        let timestamp = Date(timeIntervalSince1970: 42)

        let unavailableSnapshot = liveSnapshot.replacingTelemetryUnavailable(
            note: "Waiting for telemetry to resume…",
            statusText: "Reconnecting…",
            timestamp: timestamp
        )

        XCTAssertEqual(liveSnapshot.menuBarTitle, "RAM 75% GPU 37%")
        XCTAssertEqual(unavailableSnapshot.menuBarTitle, "RAM -- GPU --")
        XCTAssertEqual(unavailableSnapshot.memory.detailText, "Reconnecting…")
        XCTAssertEqual(unavailableSnapshot.memory.menuDetailText, "--")
        XCTAssertEqual(unavailableSnapshot.gpu.detailText, "Reconnecting…")
        XCTAssertEqual(unavailableSnapshot.gpu.menuDetailText, "--")
        XCTAssertEqual(unavailableSnapshot.gpu.summaryText, "GPU")
        XCTAssertEqual(unavailableSnapshot.gpu.note, "Waiting for telemetry to resume…")
        XCTAssertEqual(unavailableSnapshot.timestamp, timestamp)
    }

    func testLiveSnapshotComputesMenuBarAndDetailValues() {
        let sample = TelemetrySample(
            gpuUtilizationPercent: 37,
            memoryTotalMB: 65_536,
            memoryAvailableMB: 16_384
        )

        let snapshot = MetricsSnapshot.live(sample)
        let detailText = localizedMemoryDetailText(percent: "75%", usedGiB: 48, totalGiB: 64)

        XCTAssertEqual(snapshot.menuBarTitle, "RAM 75% GPU 37%")
        XCTAssertEqual(snapshot.memory.detailText, detailText)
        XCTAssertEqual(snapshot.memory.menuDetailText, detailText)
        XCTAssertEqual(snapshot.gpu.detailText, "37%")
        XCTAssertEqual(snapshot.gpu.menuDetailText, "37%")
        XCTAssertEqual(snapshot.gpu.summaryText, "GPU 37%")
    }

    func testLiveSnapshotRoundsDisplayedTotalMemoryUp() {
        let sample = TelemetrySample(
            gpuUtilizationPercent: 0,
            memoryTotalMB: 130_764.8,
            memoryAvailableMB: 127_897.6
        )

        let snapshot = MetricsSnapshot.live(sample)

        XCTAssertEqual(snapshot.menuBarTitle, "RAM 2% GPU 0%")
        XCTAssertEqual(
            snapshot.memory.detailText,
            localizedMemoryDetailText(percent: "2%", usedGiB: 2.8, totalGiB: 128)
        )
    }

    func testLiveSnapshotClampsNegativeUsedMemoryToZero() {
        let sample = TelemetrySample(
            gpuUtilizationPercent: 91,
            memoryTotalMB: 4_096,
            memoryAvailableMB: 8_192
        )

        let snapshot = MetricsSnapshot.live(sample)

        XCTAssertEqual(
            snapshot.memory.detailText,
            localizedMemoryDetailText(percent: "0%", usedGiB: 0, totalGiB: 4)
        )
        XCTAssertEqual(snapshot.memory.percentText, "0%")
    }

    func testFractionalMemoryTotalKeepsMenuAndHistoryPercentagesConsistent() {
        let sample = TelemetrySample(
            gpuUtilizationPercent: 37,
            memoryTotalMB: 130_764.8,
            memoryAvailableMB: 130_764.8 * 0.094
        )
        let snapshot = MetricsSnapshot.live(sample)
        var history = TelemetryHistory()
        history.append(sample, at: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(snapshot.menuBarTitle, "RAM 91% GPU 37%")
        XCTAssertEqual(snapshot.memory.totalGiB, 128)
        XCTAssertEqual(snapshot.memory.percentUsed ?? -1, 90.6, accuracy: 1e-9)
        XCTAssertEqual(history.samples[0].memoryPercent, snapshot.memory.percentUsed ?? -1, accuracy: 1e-9)
    }

    func testUsedMemoryFormattingUsesTwoFractionDigitsAndLocaleDecimalSeparator() {
        XCTAssertEqual(
            MetricNumberFormat.usedMemoryGiBString(2.55, locale: Locale(identifier: "en_US")),
            "2.55"
        )
        XCTAssertEqual(
            MetricNumberFormat.usedMemoryGiBString(2.55, locale: Locale(identifier: "de_DE")),
            "2,55"
        )
        XCTAssertEqual(
            MetricNumberFormat.usedMemoryGiBString(2, locale: Locale(identifier: "en_US")),
            "2.00"
        )
    }

    func testTelemetryParserDecodesFirstSampleFromPayload() throws {
        let payload = Data(
            """
            {
              "TelemetryForGPUs": [
                {
                  "percentage_utilization": 37.0,
                  "memory_total_in_mb": 65536,
                  "memory_available_in_mb": 32768
                },
                {
                  "percentage_utilization": 12.0,
                  "memory_total_in_mb": 65536,
                  "memory_available_in_mb": 49152
                }
              ]
            }
            """.utf8
        )

        let sample = try TelemetryParser.firstSample(from: payload)

        XCTAssertEqual(sample.gpuUtilizationPercent, 37.0)
        XCTAssertEqual(sample.memoryTotalMB, 65_536)
        XCTAssertEqual(sample.memoryAvailableMB, 32_768)
    }

    func testTelemetryParserRejectsEmptyPayloads() {
        let payload = Data(#"{"TelemetryForGPUs":[]}"#.utf8)

        XCTAssertThrowsError(try TelemetryParser.firstSample(from: payload))
    }

    func testUpdateAvailabilityDecodesAvailableFlag() throws {
        let payload = Data(#"{"available":true}"#.utf8)

        let availability = try JSONDecoder().decode(UpdateAvailability.self, from: payload)

        XCTAssertTrue(availability.available)
    }

    func testNVIDIASyncMonitorMatchesKnownAppIdentifiers() {
        XCTAssertTrue(
            NVIDIASyncAppMonitor.matches(
                bundleIdentifier: nil,
                localizedName: "NVIDIA Sync",
                bundleName: nil
            )
        )
        XCTAssertTrue(
            NVIDIASyncAppMonitor.matches(
                bundleIdentifier: "com.nvidia.sync",
                localizedName: nil,
                bundleName: nil
            )
        )
        XCTAssertTrue(
            NVIDIASyncAppMonitor.matches(
                bundleIdentifier: nil,
                localizedName: nil,
                bundleName: "NVIDIA Sync.app"
            )
        )
        XCTAssertFalse(
            NVIDIASyncAppMonitor.matches(
                bundleIdentifier: "com.example.other",
                localizedName: "Other App",
                bundleName: "Other App.app"
            )
        )
    }

    func testDashboardConnectivityMessageMentionsManualSSHTunnelWhenNVIDIASyncIsNotRunning() {
        let message = DashboardConnectionMessage.message(
            for: URLError(.cannotConnectToHost),
            syncAppState: .notRunning
        )

        XCTAssertEqual(
            message,
            "Expose DGX Dashboard at 127.0.0.1:11000 with NVIDIA Sync or a manual SSH tunnel: ssh -L 11000:localhost:11000 <username>@<IP-or-spark-hostname.local>"
        )
    }

    func testDashboardConnectivityMessageMentionsDashboardOrManualSSHTunnelWhenNVIDIASyncIsRunning() {
        let message = DashboardConnectionMessage.message(
            for: URLError(.cannotConnectToHost),
            syncAppState: .running
        )

        XCTAssertEqual(
            message,
            "NVIDIA Sync is running. Open DGX Dashboard, or keep a manual SSH tunnel forwarding 127.0.0.1:11000."
        )
    }

    func testDashboardConnectionMessagePreservesNonConnectivityErrors() {
        let message = DashboardConnectionMessage.message(
            for: URLError(.badServerResponse),
            syncAppState: .notRunning
        )

        XCTAssertEqual(message, URLError(.badServerResponse).localizedDescription)
    }

    private func localizedMemoryDetailText(percent: String, usedGiB: Double, totalGiB: Double) -> String {
        let usedText = MetricNumberFormat.usedMemoryGiBString(usedGiB)
        let totalText = MetricNumberFormat.wholeNumberString(totalGiB)
        return "\(percent) (\(usedText) / \(totalText) GB)"
    }
}
