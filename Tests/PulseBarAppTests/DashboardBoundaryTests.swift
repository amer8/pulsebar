import Foundation
import XCTest

@testable import PulseBarApp

final class DashboardBoundaryTests: XCTestCase {
    func testInvalidLoginTokensAreRejected() async throws {
        for scenario in [DashboardFixture.Scenario.loginEmptyToken, .loginInvalidToken] {
            let server = try await DashboardFixture(scenario: scenario)
            let session = URLSession(configuration: .ephemeral)
            defer {
                session.invalidateAndCancel()
                server.stop()
            }
            do {
                _ = try await DashboardClient(baseURL: server.url, session: session).login(username: "demo", password: "demo")
                XCTFail("Invalid login token was accepted")
            } catch DashboardError.invalidSessionToken {
                // Expected.
            }
        }
    }

    func testInvalidTokensNeverStartAuthenticatedRequests() async throws {
        let server = try await DashboardFixture(scenario: .live)
        let session = URLSession(configuration: .ephemeral)
        defer {
            session.invalidateAndCancel()
            server.stop()
        }
        let client = DashboardClient(baseURL: server.url, session: session)
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

    func testSameOriginRedirectsPreserveDashboardRequests() async throws {
        let server = try await DashboardFixture(scenario: .live, redirectLocation: "same-origin")
        let session = URLSession(configuration: .ephemeral)
        defer {
            session.invalidateAndCancel()
            server.stop()
        }
        let client = DashboardClient(baseURL: server.url, session: session)
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
        while !(await tracker.hasSample) {
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
        let session = URLSession(configuration: .ephemeral)
        defer {
            session.invalidateAndCancel()
            server.stop()
            destination.stop()
        }
        let client = DashboardClient(baseURL: server.url, session: session)
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
            let session = URLSession(configuration: .ephemeral)
            defer {
                session.invalidateAndCancel()
                server.stop()
            }
            let client = DashboardClient(baseURL: server.url, session: session)
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
    private(set) var hasSample = false
    func received() { hasSample = true }
}

private enum BoundaryFixtureError: Error { case timeout }
