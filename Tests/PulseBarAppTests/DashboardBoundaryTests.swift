import Foundation
import XCTest

@testable import PulseBarApp

final class DashboardBoundaryTests: XCTestCase {
    func testConnectionProbeFinishesAtResponseHeaders() async throws {
        let headers = Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n".utf8)
        let server = try await DashboardFixture(scenario: .live, responseOverride: headers, keepResponseOpen: true)
        defer { server.stop() }
        let reachable = try await DashboardClient(fixtureURL: server.url).checkConnection()
        XCTAssertTrue(reachable)
    }

    func testLoginAndUpdateBoundJSONWhileReadingSuccessAndErrorBodies() async throws {
        for status in ["200 OK", "503 Service Unavailable"] {
            let response =
                Data("HTTP/1.1 \(status)\r\nConnection: close\r\n\r\n".utf8)
                + Data(repeating: 32, count: DashboardClient.maximumJSONBytes + 1)
            let server = try await DashboardFixture(scenario: .live, responseOverride: response)
            defer { server.stop() }
            let client = DashboardClient(fixtureURL: server.url)
            do {
                _ = try await client.login(username: "demo", password: "demo")
                XCTFail("Accepted oversized login response")
            } catch DashboardError.responseTooLarge {}
            do {
                _ = try await client.updateAvailability(token: "fixture-token")
                XCTFail("Accepted oversized update response")
            } catch DashboardError.responseTooLarge {}
        }
    }

    func testCookieFromOneDashboardIsAbsentOnSecondPort() async throws {
        let response = Data("HTTP/1.1 200 OK\r\nSet-Cookie: fixture=one; Path=/\r\nContent-Length: 0\r\n\r\n".utf8)
        let first = try await DashboardFixture(scenario: .live, responseOverride: response)
        defer { first.stop() }
        let second = try await DashboardFixture(scenario: .live)
        defer { second.stop() }
        _ = try await DashboardClient(fixtureURL: first.url).checkConnection()
        _ = try await DashboardClient(fixtureURL: second.url).checkConnection()
        XCTAssertNil(try XCTUnwrap(second.requests.first).headers["cookie"])
    }

    func testInvalidLoginTokensAreRejected() async throws {
        for scenario in [DashboardFixture.Scenario.loginEmptyToken, .loginInvalidToken] {
            let server = try await DashboardFixture(scenario: scenario)
            defer {
                server.stop()
            }
            do {
                _ = try await DashboardClient(fixtureURL: server.url).login(username: "demo", password: "demo")
                XCTFail("Invalid login token was accepted")
            } catch DashboardError.invalidSessionToken {
                // Expected.
            }
        }
    }

    func testInvalidTokensNeverStartAuthenticatedRequests() async throws {
        let server = try await DashboardFixture(scenario: .live)
        defer {
            server.stop()
        }
        let client = DashboardClient(fixtureURL: server.url)
        for token in ["", " ", "bad\r\nvalue", "a=b", "é"] {
            do {
                _ = try await client.updateAvailability(token: token)
                XCTFail("Invalid token was accepted")
            } catch DashboardError.invalidSessionToken {}
            do {
                try await client.consumeTelemetryStream(token: token, onSample: { _ in })
                XCTFail("Invalid token was accepted")
            } catch DashboardError.invalidSessionToken {}
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testRejectsOversizedLineBeforeItsTerminator() async throws {
        let line = String(repeating: "x", count: DashboardClient.maximumLineBytes + 1)
        do {
            try await consumeStream(line)
            XCTFail("Accepted an oversized unterminated line")
        } catch DashboardError.telemetryLineTooLong {}
    }

    func testEmptyDataFieldsCountTowardEventLimit() async throws {
        let line = "data:\n"
        let limit = DashboardClient.maximumEventBytes
        let fields = String(repeating: line, count: limit / line.utf8.count)
        let tail = String(repeating: "x", count: limit - fields.utf8.count + 1)
        do {
            try await consumeStream(fields + tail)
            XCTFail("Accepted an oversized unterminated event")
        } catch DashboardError.telemetryEventTooLarge {}
    }

    func testConsecutiveEventsAtSizeLimitsDeliverBothSamples() async throws {
        let payload = #"{"TelemetryForGPUs":[{"percentage_utilization":37,"memory_total_in_mb":100,"memory_available_in_mb":50}]}"#
        var event = "event: gpu_telemetry\ndata: \(payload)\n"
        let fullLine = "data:" + String(repeating: " ", count: DashboardClient.maximumLineBytes - 5) + "\n"
        while event.utf8.count + fullLine.utf8.count + 2 <= DashboardClient.maximumEventBytes {
            event += fullLine
        }
        let padding = DashboardClient.maximumEventBytes - event.utf8.count - 2
        event += String(repeating: " ", count: padding) + "\n\n"

        let tracker = SampleTracker()
        try await consumeStream(event + event.replacingOccurrences(of: "\n", with: "\r\n"), onSample: { _ in await tracker.received() })
        let count = await tracker.count
        XCTAssertEqual(count, 2)
    }

    func testIsolatedUnknownEventsDoNotWarnAcrossValidSamples() async throws {
        let unknown = "event: unrelated\ndata: {}\n\n"
        let payload = #"{"TelemetryForGPUs":[{"percentage_utilization":37,"memory_total_in_mb":100,"memory_available_in_mb":50}]}"#
        let body = unknown + unknown + "event: gpu_telemetry\ndata: \(payload)\n\n" + unknown + unknown
        let tracker = SampleTracker()
        try await consumeStream(
            body,
            onStatus: { status in
                if case .unrecognizedEvent = status { XCTFail("Short runs of unrelated events should be ignored") }
            },
            onSample: { _ in await tracker.received() })
        let count = await tracker.count
        XCTAssertEqual(count, 1)
    }

    private func consumeStream(
        _ body: String, onStatus: @escaping @Sendable (TelemetryStreamStatus) async -> Void = { _ in },
        onSample: @escaping @Sendable (TelemetrySample) async -> Void = { _ in XCTFail("Unexpected sample") }
    ) async throws {
        let server = try await DashboardFixture(scenario: .live, firstStreamBody: Data(body.utf8))
        defer {
            server.stop()
        }
        try await DashboardClient(fixtureURL: server.url).consumeTelemetryStream(
            token: "simulator-token", onStatus: onStatus, onSample: onSample)
    }

    func testSameOriginRedirectsPreserveDashboardRequests() async throws {
        let server = try await DashboardFixture(scenario: .live, redirectLocation: "same-origin")
        defer {
            server.stop()
        }
        let client = DashboardClient(fixtureURL: server.url)
        let token = try await client.login(username: "demo", password: "demo")
        XCTAssertEqual(token, "simulator-token")
        let availability = try await client.updateAvailability(token: token)
        XCTAssertFalse(availability.available)
        let tracker = SampleTracker()
        let stream = Task {
            try await client.consumeTelemetryStream(token: token, onSample: { _ in await tracker.received() })
        }
        defer { stream.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await tracker.count == 0 {
            guard ContinuousClock.now < deadline else { throw BoundaryFixtureError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
        stream.cancel()
        _ = try? await stream.value
        let requests = server.requests
        let login = try XCTUnwrap(requests.first { $0.path == "/redirected/api/login" })
        XCTAssertEqual(login.method, "POST")
        let credentials = try XCTUnwrap(try JSONSerialization.jsonObject(with: login.body) as? [String: String])
        XCTAssertEqual(credentials, ["username": "demo", "password": "demo"])
        for path in ["/redirected/api/v1/updates/available", "/redirected/api/v1/gpu_telemetry/stream"] {
            XCTAssertEqual(requests.first { $0.path == path }?.headers["authorization"], "Bearer simulator-token")
        }
    }

    func testRedirectChainCannotEscapeOrigin() async throws {
        let destination = try await DashboardFixture(scenario: .live)
        let server = try await DashboardFixture(
            scenario: .live, redirectLocation: "same-origin",
            redirectAfterSameOrigin: destination.url.absoluteString + "/capture")
        defer {
            server.stop()
            destination.stop()
        }
        let client = DashboardClient(fixtureURL: server.url)
        do {
            _ = try await client.login(username: "demo", password: "demo")
            XCTFail("Redirect accepted")
        } catch {}
        do {
            _ = try await client.updateAvailability(token: "simulator-token")
            XCTFail("Redirect accepted")
        } catch {}
        do {
            try await client.consumeTelemetryStream(token: "simulator-token", onSample: { _ in })
            XCTFail("Redirect accepted")
        } catch {}
        XCTAssertEqual(server.requests.count, 6)
        XCTAssertTrue(destination.requests.isEmpty)
    }

    func testCrossOriginRedirectsNeverReceiveCredentials() async throws {
        let destination = try await DashboardFixture(scenario: .live)
        defer { destination.stop() }
        for status in [301, 302, 303, 307, 308] {
            let server = try await DashboardFixture(
                scenario: .live, redirectLocation: destination.url.absoluteString + "/capture", redirectStatus: status)
            defer {
                server.stop()
            }
            let client = DashboardClient(fixtureURL: server.url)
            do {
                _ = try await client.login(username: "demo", password: "demo")
                XCTFail("Redirect accepted")
            } catch {}
            do {
                _ = try await client.updateAvailability(token: "simulator-token")
                XCTFail("Redirect accepted")
            } catch {}
            do {
                try await client.consumeTelemetryStream(token: "simulator-token", onSample: { _ in })
                XCTFail("Redirect accepted")
            } catch {}
            XCTAssertEqual(server.requests.count, 3)
            XCTAssertTrue(destination.requests.isEmpty, "Cross-origin redirect followed for status \(status)")
        }
    }
}

private actor SampleTracker {
    private(set) var count = 0
    func received() { count += 1 }
}

private enum BoundaryFixtureError: Error { case timeout }
