import Foundation
import Security
import XCTest

@testable import PulseBarApp

@MainActor
final class AuthenticationTests: XCTestCase {
    func testSuccessfulLoginSavesSessionAndClearsPassword() async throws {
        let dashboard = ControlledDashboard()
        let store = AuthenticationSessionStore()
        let model = MetricsViewModel(dashboard: dashboard, sessionStore: store)
        defer { model.signOut() }
        model.username = " demo \n"
        model.password = "fake-password"

        let task = try XCTUnwrap(model.signIn())
        XCTAssertTrue(model.isAuthenticating)
        XCTAssertFalse(model.canSignIn)
        try await waitForLogin(dashboard, count: 1)
        let request = await dashboard.requests.first
        XCTAssertEqual(request?.username, "demo")
        XCTAssertEqual(request?.password, "fake-password")
        await dashboard.completeLogin(at: 0, with: .success("fake-token"))
        await task.value

        XCTAssertTrue(model.isSignedIn)
        XCTAssertFalse(model.isAuthenticating)
        XCTAssertEqual(model.username, "demo")
        XCTAssertEqual(model.password, "")
        XCTAssertEqual(store.username, "demo")
        XCTAssertEqual(store.token, "fake-token")
    }

    func testRejectedCredentialsClearTransientCredentials() async throws {
        let dashboard = ControlledDashboard()
        let store = AuthenticationSessionStore()
        let model = MetricsViewModel(dashboard: dashboard, sessionStore: store)
        defer { model.signOut() }
        model.username = "demo"
        model.password = "wrong-password"
        let task = try XCTUnwrap(model.signIn())
        try await waitForLogin(dashboard, count: 1)
        await dashboard.completeLogin(at: 0, with: .failure(DashboardError.loginFailed))
        await task.value

        XCTAssertFalse(model.isSignedIn)
        XCTAssertFalse(model.isAuthenticating)
        XCTAssertEqual(model.password, "")
        XCTAssertNil(store.token)
        XCTAssertEqual(store.username, "")
        XCTAssertEqual(model.snapshot.gpu.note, DashboardError.loginFailed.localizedDescription)
    }

    func testTokenSaveFailureDoesNotStartAuthenticatedRequests() async throws {
        let dashboard = ControlledDashboard()
        let store = AuthenticationSessionStore()
        store.saveError = SessionStoreError.keychainSaveFailed(errSecAuthFailed)
        let model = MetricsViewModel(dashboard: dashboard, sessionStore: store)
        defer { model.signOut() }
        model.username = "demo"
        model.password = "fake-password"
        let task = try XCTUnwrap(model.signIn())
        try await waitForLogin(dashboard, count: 1)
        await dashboard.completeLogin(at: 0, with: .success("unsaved-token"))
        await task.value

        XCTAssertFalse(model.isSignedIn)
        XCTAssertFalse(model.isAuthenticating)
        XCTAssertEqual(model.password, "")
        XCTAssertNil(store.token)
        XCTAssertEqual(store.username, "")
        XCTAssertTrue(model.snapshot.gpu.note?.contains("could not save") == true)
        let authenticatedRequests = await dashboard.authenticatedRequests
        XCTAssertTrue(authenticatedRequests.isEmpty)
    }

    func testDuplicateSubmissionDoesNotStartAnotherLogin() async throws {
        let dashboard = ControlledDashboard()
        let model = MetricsViewModel(dashboard: dashboard, sessionStore: AuthenticationSessionStore())
        defer { model.signOut() }
        model.username = "demo"
        model.password = "fake-password"
        let task = try XCTUnwrap(model.signIn())
        XCTAssertNil(model.signIn())
        try await waitForLogin(dashboard, count: 1)
        await dashboard.completeLogin(at: 0, with: .success("fake-token"))
        await task.value
        let requestCount = await dashboard.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testSignOutCannotBeUndoneByLateLoginSuccess() async throws {
        let dashboard = ControlledDashboard()
        let store = AuthenticationSessionStore()
        let model = MetricsViewModel(dashboard: dashboard, sessionStore: store)
        defer { model.signOut() }
        model.username = "demo"
        model.password = "fake-password"
        let task = try XCTUnwrap(model.signIn())
        try await waitForLogin(dashboard, count: 1)
        model.signOut()
        await dashboard.completeLogin(at: 0, with: .success("late-token"))
        await task.value

        XCTAssertFalse(model.isSignedIn)
        XCTAssertFalse(model.isAuthenticating)
        XCTAssertEqual(model.username, "")
        XCTAssertEqual(model.password, "")
        XCTAssertNil(store.token)
        XCTAssertEqual(model.connectionHealth.state, .signedOut)
        let authenticatedRequests = await dashboard.authenticatedRequests
        XCTAssertTrue(authenticatedRequests.isEmpty)
    }

    func testLateLoginResultsCannotOverwriteANewerSession() async throws {
        // The transport deliberately ignores cancellation, as a late response can still arrive.
        for oldResult: Result<String, Error> in [.success("old-token"), .failure(DashboardError.loginFailed)] {
            let dashboard = ControlledDashboard()
            let store = AuthenticationSessionStore()
            let model = MetricsViewModel(dashboard: dashboard, sessionStore: store)
            defer { model.signOut() }
            model.username = "old-user"
            model.password = "old-password"
            let oldTask = try XCTUnwrap(model.signIn())
            try await waitForLogin(dashboard, count: 1)
            model.signOut()
            model.username = "new-user"
            model.password = "new-password"
            let newTask = try XCTUnwrap(model.signIn())
            try await waitForLogin(dashboard, count: 2)
            await dashboard.completeLogin(at: 1, with: .success("new-token"))
            await newTask.value
            await dashboard.completeLogin(at: 0, with: oldResult)
            await oldTask.value

            XCTAssertTrue(model.isSignedIn)
            XCTAssertFalse(model.isAuthenticating)
            XCTAssertEqual(model.username, "new-user")
            XCTAssertEqual(store.username, "new-user")
            XCTAssertEqual(store.token, "new-token")
        }
    }

    func testCancelledLoginDoesNotPersistItsResponse() async throws {
        let dashboard = ControlledDashboard()
        let store = AuthenticationSessionStore()
        let model = MetricsViewModel(dashboard: dashboard, sessionStore: store)
        defer { model.signOut() }
        model.username = "demo"
        model.password = "fake-password"
        let task = try XCTUnwrap(model.signIn())
        try await waitForLogin(dashboard, count: 1)
        task.cancel()
        await dashboard.completeLogin(at: 0, with: .success("cancelled-token"))
        await task.value

        XCTAssertFalse(model.isSignedIn)
        XCTAssertFalse(model.isAuthenticating)
        XCTAssertEqual(model.password, "")
        XCTAssertNil(store.token)
        XCTAssertEqual(model.snapshot.gpu.note, "Sign-in cancelled.")
    }

    private func waitForLogin(_ dashboard: ControlledDashboard, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await dashboard.requests.count < count {
            guard ContinuousClock.now < deadline else { throw AuthenticationFixtureError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum AuthenticationFixtureError: Error { case timeout }

private actor ControlledDashboard: DashboardServing {
    struct LoginRequest: Sendable {
        let username: String
        let password: String
    }
    private(set) var requests: [LoginRequest] = []
    private(set) var authenticatedRequests: [String] = []
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]

    func login(username: String, password: String) async throws -> String {
        let index = requests.count
        requests.append(LoginRequest(username: username, password: password))
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func completeLogin(at index: Int, with result: Result<String, Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }

    func checkConnection() async throws -> Bool { true }

    func updateAvailability(token: String) async throws -> UpdateAvailability {
        authenticatedRequests.append(token)
        return UpdateAvailability(available: false)
    }

    func consumeTelemetryStream(
        token: String,
        onLog: @escaping @Sendable (String) -> Void,
        onConnected: @escaping @Sendable () async -> Void,
        onSample: @escaping @Sendable (TelemetrySample) async -> Void
    ) async throws {
        authenticatedRequests.append(token)
        await onConnected()
        try await Task.sleep(for: .seconds(3600))
    }
}

@MainActor
private final class AuthenticationSessionStore: DashboardSessionStoring {
    private(set) var username = ""
    private(set) var token: String?
    var saveError: (any Error)?
    func loadUsername() -> String { username }
    func saveUsername(_ username: String) { self.username = username }
    func clearUsername() { username = "" }
    func loadToken() -> String? { token }
    func saveToken(_ token: String) throws {
        if let saveError { throw saveError }
        self.token = token
    }
    func clearToken() { token = nil }
}
