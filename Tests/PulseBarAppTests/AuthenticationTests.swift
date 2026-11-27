import Foundation
import PulseBarUI
import Security
import XCTest

@testable import PulseBarApp
@testable import PulseBarTools

@MainActor
final class AuthenticationTests: XCTestCase {
    func testPreferencesScopeAccountActionsToTheAppliedProfile() throws {
        let endpoint = try DashboardEndpoint(port: 11000, sshHost: "dgx")
        let model = MetricsViewModel(dashboard: ControlledDashboard(), sessionStore: AuthenticationSessionStore(), endpoint: endpoint)
        model.username = "demo"
        model.password = "fixture"
        var applied = model.preferencesState(port: "11000", host: "dgx")
        XCTAssertEqual(applied.edit, .applied)
        XCTAssertFalse(applied.canApply)
        XCTAssertTrue(applied.canUseProfile)
        XCTAssertFalse(applied.canSignIn)
        XCTAssertFalse(applied.showsAccount)
        applied.connectionVerified = true
        XCTAssertTrue(applied.showsAccount)
        XCTAssertEqual(applied.accountHeading, "Sign in to DGX Dashboard on dgx")
        XCTAssertNil(applied.accountName)
        XCTAssertTrue(applied.canSignIn)

        let invalid = model.preferencesState(port: "70000", host: "dgx")
        guard case .invalid = invalid.edit else { return XCTFail("Expected a port validation error") }
        let pending = model.preferencesState(port: "11001", host: "lab")
        XCTAssertEqual(pending.edit, .pending("lab · 11001"))
        XCTAssertTrue(pending.canApply)
        XCTAssertFalse(invalid.canApply)
        for state in [invalid, pending] {
            XCTAssertEqual(state.accountHeading, "DGX Dashboard account on dgx")
            XCTAssertFalse(state.showsAccount)
            XCTAssertFalse(state.canUseProfile)
            XCTAssertFalse(state.canSignIn)
        }

        let newProfile = MetricsViewModel(dashboard: ControlledDashboard(), sessionStore: AuthenticationSessionStore(), endpoint: .standard)
        let setup = newProfile.preferencesState(port: "11000", host: "")
        XCTAssertEqual(setup.edit, .unconfigured)
        XCTAssertFalse(setup.canSignIn)
    }

    func testSignedInAccountShowsEndpointDetailOnlyForCustomPort() throws {
        for port in [11000, 12000] {
            let endpoint = try DashboardEndpoint(port: port, sshHost: "dgx")
            let store = AuthenticationSessionStore()
            store.saveUsername("demo")
            try store.saveToken("fixture-token")
            let model = MetricsViewModel(dashboard: ControlledDashboard(), sessionStore: store, endpoint: endpoint)
            defer { model.signOut() }

            let state = model.preferencesState(port: String(port), host: "dgx")
            XCTAssertTrue(state.showsAccount)
            XCTAssertEqual(state.accountName, "demo")
            XCTAssertEqual(state.accountHeading, "DGX Dashboard account on dgx")
            XCTAssertEqual(state.accountEndpointDetail, port == 11000 ? nil : "Dashboard port 12000")
        }
    }

    func testMigrationHintRequiresAPreviousPortAndSetupHidesAccountUntilVerified() throws {
        let name = "PulseBar.Onboarding.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MetricsViewModel(dashboard: ControlledDashboard(), sessionStore: AuthenticationSessionStore(), endpoint: .standard)
        defaults.set(true, forKey: "PulseBar.HasSeenWelcome")
        XCTAssertFalse(model.preferencesState(port: "11000", host: "", defaults: defaults).isPortOnlyUpgrade)
        defaults.set(12000, forKey: DashboardEndpoint.preferenceKey)
        XCTAssertTrue(model.preferencesState(port: "12000", host: "", defaults: defaults).isPortOnlyUpgrade)
        for sample in [PreferencesSample.setup, .advanced, .addDGX, .verifyDGX] {
            XCTAssertFalse(sample.presentation.showsAccount)
            XCTAssertFalse(sample.presentation.canSignIn)
        }
        XCTAssertTrue(PreferencesSample.signedOut.presentation.showsAccount)
    }

    func testPreferencesTabs() {
        XCTAssertEqual(PreferencesPane.allCases.map(\.rawValue), ["Devices", "General"])
    }

    func testNVIDIASyncReportsOnlyLaunchFailures() async {
        var failures = 0
        await PulseBarNavigation.openNVIDIASync(using: { true }, onFailure: { failures += 1 })
        XCTAssertEqual(failures, 0)
        await PulseBarNavigation.openNVIDIASync(using: { false }, onFailure: { failures += 1 })
        XCTAssertEqual(failures, 1)
    }

    func testNativePreviewFixturesRespectProfileAndSessionState() {
        let invalid = PreferencesSample.invalidPort.presentation
        XCTAssertFalse(invalid.canSignIn)
        XCTAssertFalse(invalid.canApply)
        XCTAssertFalse(invalid.canUseProfile)
        XCTAssertTrue(PreferencesSample.paused.presentation.isPaused)
        XCTAssertTrue(PreferencesSample.signOutFailed.presentation.removalFailed)
        let expired = TelemetryPanelState.expiredSession()
        XCTAssertTrue(expired.points.isEmpty)
        XCTAssertNil(expired.lastSampleAt)
        XCTAssertEqual(expired.recoveryAction, .signIn)
    }

    func testLoginRequiresTheAppliedAliasAndPort() async throws {
        let dashboard = ControlledDashboard()
        let model = MetricsViewModel(
            dashboard: dashboard, sessionStore: AuthenticationSessionStore(), endpoint: try DashboardEndpoint(port: 11000, sshHost: "dgx"))
        defer { model.signOut() }
        model.username = "demo"
        model.password = "fixture"
        for edit in ["11001", "invalid", ""] { XCTAssertNil(model.signIn(portText: edit, sshHost: "dgx")) }
        XCTAssertNil(model.signIn(portText: "11000", sshHost: "another-dgx"))
        let task = try XCTUnwrap(model.signIn(portText: " 11000 ", sshHost: " dgx "))
        try await waitForLogin(dashboard, count: 1)
        let signingIn = model.panelState(at: .now, historyWindow: .fiveMinutes)
        XCTAssertTrue(signingIn.isAuthenticating)
        XCTAssertEqual(signingIn.connectionTitle, "Signing in…")
        XCTAssertFalse(signingIn.needsSignIn)
        XCTAssertFalse(signingIn.canReconnect)
        let preferences = model.preferencesState(port: "11000", host: "dgx")
        XCTAssertFalse(preferences.canUseProfile)
        XCTAssertEqual(preferences.connectionTitle, signingIn.connectionTitle)
        XCTAssertTrue(
            MenuBarPresentation(state: model.connectionHealth.state, snapshot: model.snapshot).accessibilityLabel.contains("Signing in"))
        await dashboard.completeLogin(at: 0, with: .success("fixture-token"))
        await task.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.connectionHealth.state != .waiting {
            guard ContinuousClock.now < deadline else { throw AuthenticationFixtureError.timeout }
            await Task.yield()
        }
        let waiting = model.panelState(at: .now, historyWindow: .fiveMinutes)
        XCTAssertFalse(waiting.isAuthenticating)
        XCTAssertFalse(waiting.needsSignIn)
        XCTAssertTrue(waiting.canReconnect)
        XCTAssertEqual(waiting.connectionTitle, "Waiting for telemetry…")
        let result = await model.testConnection()
        XCTAssertEqual(result.tone, .success)
        XCTAssertEqual(result.message, "Dashboard reachable over SSH on dgx, port 11000.")
        let count = await dashboard.requests.count
        XCTAssertEqual(count, 1)
    }

    func testInvalidLoginTokenDoesNotPersistOrStartRequests() async throws {
        for token in ["", " ", "bad\nheader", "a=b"] {
            let dashboard = ControlledDashboard()
            let store = AuthenticationSessionStore()
            let model = MetricsViewModel(dashboard: dashboard, sessionStore: store)
            model.username = "demo"
            model.password = "password"
            let task = try XCTUnwrap(model.signIn())
            try await waitForLogin(dashboard, count: 1)
            await dashboard.completeLogin(at: 0, with: .success(token))
            await task.value
            XCTAssertFalse(model.isSignedIn)
            XCTAssertNil(store.token)
            XCTAssertEqual(store.username, "")
            let requests = await dashboard.authenticatedRequests
            XCTAssertTrue(requests.isEmpty)
            model.signOut()
        }
    }

    func testPickerPublishesOnlyTheUsernameAcceptedByTheSelectedDashboard() async throws {
        let dashboard = ControlledDashboard()
        let sessions = DeviceSessions(defaults: nil) { endpoint in
            MetricsViewModel(dashboard: dashboard, sessionStore: AuthenticationSessionStore(), endpoint: endpoint)
        }
        sessions.didVerify(try DashboardEndpoint(port: 11000, sshHost: "desk"))
        sessions.didVerify(try DashboardEndpoint(port: 12000, sshHost: "lab"))
        let lab = sessions.managed
        defer { lab.signOut() }
        lab.username = "draft"
        lab.password = "fixture"
        let rejected = try XCTUnwrap(lab.signIn())
        try await waitForLogin(dashboard, count: 1)
        XCTAssertEqual(sessions.devices.map(\.username), [nil, nil])
        await dashboard.completeLogin(at: 0, with: .failure(DashboardError.loginFailed))
        await rejected.value
        XCTAssertEqual(sessions.devices.map(\.username), [nil, nil])

        lab.username = " lab-admin "
        lab.password = "fixture"
        let accepted = try XCTUnwrap(lab.signIn())
        try await waitForLogin(dashboard, count: 2)
        await dashboard.completeLogin(at: 1, with: .success("fixture-token"))
        await accepted.value
        XCTAssertEqual(sessions.displayed.endpoint.sshHost, "desk")
        XCTAssertEqual(sessions.panelState(at: .now, historyWindow: .minute).devices.map(\.username), [nil, "lab-admin"])
        XCTAssertEqual(sessions.devices.map(\.username), [nil, "lab-admin"])
    }

    func testInvalidSavedTokenDoesNotStartRequests() async throws {
        let dashboard = ControlledDashboard()
        let store = AuthenticationSessionStore()
        try store.saveToken("")
        store.saveUsername("demo")
        let model = MetricsViewModel(dashboard: dashboard, sessionStore: store)
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNotNil(model.sessionLoadIssue)
        model.retrySavedSession()
        XCTAssertFalse(model.isSignedIn)
        let requests = await dashboard.authenticatedRequests
        XCTAssertTrue(requests.isEmpty)
        model.signOut()
    }

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
        XCTAssertEqual(model.preferencesState(port: "11000", host: "dgx").accountNote?.tone, .error)
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

    func testSignOutFailureKeepsSessionAndAllowsRetry() async throws {
        let dashboard = ControlledDashboard()
        let store = AuthenticationSessionStore()
        let model = MetricsViewModel(
            dashboard: dashboard, sessionStore: store, endpoint: try DashboardEndpoint(port: 11000, sshHost: "dgx"))
        model.username = "demo"
        model.password = "fake-password"
        let task = try XCTUnwrap(model.signIn())
        try await waitForLogin(dashboard, count: 1)
        await dashboard.completeLogin(at: 0, with: .success("fake-token"))
        await task.value

        store.deleteError = SessionStoreError.keychainDeleteFailed(errSecAuthFailed)
        model.signOut()
        XCTAssertTrue(model.isSignedIn)
        XCTAssertEqual(store.token, "fake-token")
        XCTAssertEqual(store.username, "demo")
        XCTAssertTrue(model.sessionRemovalError?.contains("could not remove") == true)

        let retained = model.preferencesState(port: "11000", host: "dgx")
        XCTAssertTrue(retained.removalFailed)
        XCTAssertTrue(retained.canUseProfile)
        XCTAssertEqual(retained.accountName, "demo")
        XCTAssertTrue(retained.accountNote?.message.contains("still signed in") == true)
        XCTAssertEqual(retained.accountNote?.tone, .error)
        let draft = model.preferencesState(port: "11000", host: "lab")
        XCTAssertFalse(draft.canApply)
        XCTAssertFalse(draft.canUseProfile)

        store.deleteError = nil
        model.signOut()
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(store.token)
        XCTAssertEqual(store.username, "")
        XCTAssertNil(model.sessionRemovalError)
        let signedOut = model.preferencesState(port: "11000", host: "dgx")
        XCTAssertNil(signedOut.accountName)
        XCTAssertEqual(signedOut.accountNote?.message, "Signed out. PulseBar cleared this device’s saved session from Keychain.")
        XCTAssertFalse(signedOut.canSignIn)
        model.retrySavedSession()
        XCTAssertFalse(model.isSignedIn)
    }

    func testTemporaryKeychainReadFailurePreservesUsernameAndCanBeRetried() throws {
        let store = AuthenticationSessionStore()
        store.saveUsername("demo")
        try store.saveToken("saved-token")
        store.readError = SessionStoreError.keychainReadFailed(errSecInteractionNotAllowed)
        let model = MetricsViewModel(dashboard: ControlledDashboard(), sessionStore: store)
        defer { model.signOut() }

        XCTAssertFalse(model.isSignedIn)
        XCTAssertEqual(model.username, "demo")
        XCTAssertEqual(store.username, "demo")
        XCTAssertNil(model.signedInUsername)
        XCTAssertEqual(model.sessionLoadIssue, .permissionRequired)
        model.retrySavedSession()
        let failed = model.preferencesState(port: "11000", host: "dgx")
        XCTAssertEqual(failed.accountNote?.tone, .error)
        XCTAssertEqual(
            model.sessionLoadIssue, .failure(SessionStoreError.keychainReadFailed(errSecInteractionNotAllowed).userFacingMessage))

        store.readError = nil
        model.retrySavedSession()
        XCTAssertTrue(model.isSignedIn)
        XCTAssertEqual(model.username, "demo")
        XCTAssertEqual(model.signedInUsername, "demo")
        XCTAssertNil(model.sessionLoadIssue)
    }

    func testFailedLoginDoesNotDeleteAnUnreadableSavedSession() async throws {
        let store = AuthenticationSessionStore()
        store.saveUsername("saved-user")
        try store.saveToken("saved-token")
        store.readError = SessionStoreError.keychainReadFailed(errSecInteractionNotAllowed)
        let dashboard = ControlledDashboard()
        let model = MetricsViewModel(dashboard: dashboard, sessionStore: store)
        defer { model.signOut() }
        model.username = "demo"
        model.password = "wrong-password"
        let task = try XCTUnwrap(model.signIn())
        try await waitForLogin(dashboard, count: 1)
        await dashboard.completeLogin(at: 0, with: .failure(DashboardError.loginFailed))
        await task.value
        XCTAssertEqual(store.token, "saved-token")
        XCTAssertEqual(store.username, "saved-user")
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
        onStatus: @escaping @Sendable (TelemetryStreamStatus) async -> Void,
        onSample: @escaping @Sendable (TelemetrySample) async -> Void
    ) async throws {
        authenticatedRequests.append(token)
        await onStatus(.connected)
        try await Task.sleep(for: .seconds(3600))
    }
}

@MainActor
private final class AuthenticationSessionStore: DashboardSessionStoring {
    private(set) var username = ""
    private(set) var token: String?
    var saveError: (any Error)?
    var deleteError: (any Error)?
    var readError: (any Error)?
    func loadUsername() -> String { username }
    func saveUsername(_ username: String) { self.username = username }
    func clearUsername() { username = "" }
    func loadToken(allowInteraction: Bool) throws -> String? {
        if let readError { throw readError }
        return token
    }
    func saveToken(_ token: String) throws {
        if let saveError { throw saveError }
        self.token = token
    }
    func clearToken(allowInteraction: Bool) throws {
        if let deleteError { throw deleteError }
        token = nil
    }
}
