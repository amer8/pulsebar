import AppKit
import Foundation
import OSLog
import SwiftUI

private let updateAvailabilityPollInterval: Duration = .seconds(3_600)
private let updateAvailabilityRetryInterval: Duration = .seconds(30)
private let maximumTelemetryFailures = 5

@MainActor
final class MetricsViewModel: ObservableObject {
    @Published private(set) var connectionHealth = TelemetryConnectionHealth()
    @Published private(set) var history = TelemetryHistory()
    @Published private(set) var snapshot: MetricsSnapshot {
        didSet { if snapshot.gpu.utilizationPercent == nil { history.markGap() } }
    }
    @Published private(set) var isUpdateAvailable = false
    @Published private(set) var endpoint = DashboardEndpoint.current
    @Published var username: String
    @Published var password = ""
    @Published private(set) var isAuthenticating = false
    @Published private(set) var sessionRemovalError: String?
    @Published private(set) var sessionLoadError: String?

    private var dashboard: any DashboardServing
    private let syncAppMonitor: NVIDIASyncAppMonitor
    private let retrySleep: @Sendable (Duration) async throws -> Void
    private let reconnectPauseStore: DashboardReconnectPauseStore
    private var sessionStore: any DashboardSessionStoring
    private let logger = Logger(subsystem: "PulseBar", category: "Dashboard")
    private var healthTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var retryFailures = 0
    private var authToken: String?
    private var authenticationTask: Task<Void, Never>?
    private var activeAuthenticationID: UUID?
    private var streamTask: Task<Void, Never>?
    private var updateAvailabilityTask: Task<Void, Never>?
    private var activeTelemetryStreamID: UUID?
    private var activeUpdateAvailabilityTaskID: UUID?

    var isSignedIn: Bool {
        authToken != nil
    }

    var canSignIn: Bool {
        !isAuthenticating && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    init(
        syncAppMonitor: NVIDIASyncAppMonitor = .live,
        dashboard: (any DashboardServing)? = nil,
        sessionStore: (any DashboardSessionStoring)? = nil,
        demo: Bool = false,
        endpoint: DashboardEndpoint? = nil,
        reconnectPauseStore: DashboardReconnectPauseStore = DashboardReconnectPauseStore(),
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        let endpoint = endpoint ?? DashboardEndpoint.current
        let dashboard = dashboard ?? DashboardClient(baseURL: endpoint.url)
        let sessionStore = sessionStore ?? DashboardSessionStore(endpoint: endpoint)
        let username = demo ? "Demo" : sessionStore.loadUsername()
        var authToken: String?
        var loadError: String?
        if !demo {
            do { authToken = try sessionStore.loadToken() } catch { loadError = error.userFacingMessage }
        }

        self.dashboard = dashboard
        self.syncAppMonitor = syncAppMonitor
        self.retrySleep = retrySleep
        self.reconnectPauseStore = reconnectPauseStore
        self.sessionStore = sessionStore
        self.authToken = authToken
        self.sessionLoadError = loadError
        self.endpoint = endpoint

        if authToken != nil {
            self.username = username
            self.snapshot = .connecting(username: username)
        } else {
            self.username = loadError == nil ? "" : username
            self.snapshot = .signedOut()
            if !demo && loadError == nil { sessionStore.clearUsername() }
        }

        if demo {
            self.username = "Demo"
            startDemo()
            return
        }
        if let authToken {
            log("Loaded saved dashboard session for '\(username)'.")
            startSessionPollingIfAllowed(using: authToken)
        } else {
            log("No saved dashboard session found.")
        }
        monitorConnection()
    }

    private func monitorConnection() {
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.checkFreshness(at: .now)
            }
        }
        wakeTask = Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                guard !Task.isCancelled else { return }
                guard let self, self.connectionHealth.state != .paused else { continue }
                self.reconnect(resetFailures: false)
            }
        }
    }

    func checkFreshness(at date: Date) {
        guard let authToken, connectionHealth.markStale(at: date) else { return }
        snapshot = snapshot.replacingTelemetryUnavailable(note: "Telemetry is stale. Reconnecting…", statusText: "Stale", timestamp: date)
        guard recordStreamFailure() else { return }
        startStream(using: authToken)
    }

    private func startDemo() {
        streamTask = Task {
            var tick = 0.0
            while !Task.isCancelled {
                let sample = TelemetrySample(
                    gpuUtilizationPercent: 50 + 40 * sin(tick / 10), memoryTotalMB: 131_072,
                    memoryAvailableMB: 65_536 + 24_000 * cos(tick / 15))
                connectionHealth.sampleReceived(at: .now)
                history.append(sample, at: .now)
                snapshot = .live(sample)
                tick += 1
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    deinit {
        authenticationTask?.cancel()
        healthTask?.cancel()
        wakeTask?.cancel()
        streamTask?.cancel()
        updateAvailabilityTask?.cancel()
    }

    func refresh() {
        reconnect(resetFailures: true)
    }

    private func reconnect(resetFailures: Bool) {
        guard let authToken else {
            snapshot = .signedOut(note: "Sign in to the local dashboard to stream metrics.")
            return
        }

        if resetFailures {
            retryFailures = 0
            reconnectPauseStore.setPaused(false, for: endpoint)
        } else if reconnectPauseStore.isPaused(for: endpoint) {
            showPausedState()
            return
        }
        connectionHealth.reconnecting()
        snapshot = snapshot.replacingTelemetryUnavailable(
            note: "Reconnecting to the local dashboard…",
            statusText: "Reconnecting…",
            timestamp: .now
        )
        startStream(using: authToken)
        startUpdateAvailabilityChecks(using: authToken)
    }

    @discardableResult
    func signIn() -> Task<Void, Never>? {
        guard !isAuthenticating else { return nil }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !password.isEmpty else {
            snapshot = .signedOut(note: "Enter your dashboard username and password.")
            return nil
        }

        let authenticationID = UUID()
        retryFailures = 0
        activeAuthenticationID = authenticationID
        connectionHealth.beginConnection()
        isAuthenticating = true
        snapshot = .connecting(username: trimmedUsername)
        streamTask?.cancel()
        updateAvailabilityTask?.cancel()
        activeTelemetryStreamID = nil
        activeUpdateAvailabilityTaskID = nil
        authToken = nil
        isUpdateAvailable = false
        log("Signing in as '\(trimmedUsername)'.")

        let password = self.password
        authenticationTask = Task { [dashboard] in
            defer {
                if self.activeAuthenticationID == authenticationID {
                    self.isAuthenticating = false
                    self.authenticationTask = nil
                    self.activeAuthenticationID = nil
                }
            }
            do {
                let token = try await dashboard.login(username: trimmedUsername, password: password)
                try Task.checkCancellation()
                guard self.activeAuthenticationID == authenticationID else { return }
                try self.sessionStore.saveToken(token)
                self.sessionStore.saveUsername(trimmedUsername)
                self.sessionRemovalError = nil
                self.sessionLoadError = nil
                self.password = ""
                self.username = trimmedUsername
                self.authToken = token
                self.snapshot = .connecting(username: trimmedUsername)
                self.log("Login succeeded. Saved token to Keychain.")
                self.startSessionPollingIfAllowed(using: token)
            } catch {
                guard self.activeAuthenticationID == authenticationID else { return }
                let message = error is CancellationError ? "Sign-in cancelled." : self.dashboardConnectionFailureMessage(for: error)
                self.password = ""
                self.username = trimmedUsername
                self.authToken = nil
                self.activeTelemetryStreamID = nil
                self.activeUpdateAvailabilityTaskID = nil
                self.isUpdateAvailable = false
                self.connectionHealth = TelemetryConnectionHealth()
                self.snapshot = .signedOut(note: message)
                self.log("Sign-in failed: \(message)")
            }
        }
        return authenticationTask
    }

    func signOut() {
        authenticationTask?.cancel()
        authenticationTask = nil
        activeAuthenticationID = nil
        isAuthenticating = false
        password = ""
        guard removeSavedSession() else { return }
        sessionLoadError = nil
        streamTask?.cancel()
        updateAvailabilityTask?.cancel()
        streamTask = nil
        updateAvailabilityTask = nil
        activeTelemetryStreamID = nil
        activeUpdateAvailabilityTaskID = nil
        authToken = nil
        retryFailures = 0
        username = ""
        password = ""
        isUpdateAvailable = false
        connectionHealth = TelemetryConnectionHealth()
        history = TelemetryHistory()
        snapshot = .signedOut(note: "Signed out. Sign in again to resume metrics.")
        log("Signed out and cleared saved username and token.")
    }

    func configureEndpoint(_ target: DashboardEndpoint) {
        guard target != endpoint, !isAuthenticating, sessionRemovalError == nil else { return }
        streamTask?.cancel()
        updateAvailabilityTask?.cancel()
        activeTelemetryStreamID = nil
        activeUpdateAvailabilityTaskID = nil
        endpoint = target
        target.save()
        dashboard = DashboardClient(baseURL: target.url)
        sessionStore = DashboardSessionStore(endpoint: target)
        authToken = nil
        username = sessionStore.loadUsername()
        sessionLoadError = nil
        do { authToken = try sessionStore.loadToken() } catch { sessionLoadError = error.userFacingMessage }
        password = ""
        isUpdateAvailable = false
        retryFailures = 0
        history = TelemetryHistory()
        connectionHealth = TelemetryConnectionHealth()
        snapshot = authToken == nil ? .signedOut() : .connecting(username: username)
        if let authToken {
            startSessionPollingIfAllowed(using: authToken)
        }
    }

    func testConnection() async -> String {
        let target = endpoint
        do {
            guard try await dashboard.checkConnection() else {
                return "A service responded, but the dashboard page was unavailable."
            }
            return "Dashboard page is reachable at \(target.address). Sign in to verify telemetry."
        } catch { return DashboardConnectionMessage.message(for: error, syncAppState: syncAppMonitor.currentState(), endpoint: target) }
    }

    func retrySavedSession() {
        guard !isAuthenticating, authToken == nil, sessionRemovalError == nil else { return }
        do {
            guard let token = try sessionStore.loadToken() else {
                sessionLoadError = nil
                username = ""
                sessionStore.clearUsername()
                snapshot = .signedOut()
                return
            }
            sessionLoadError = nil
            username = sessionStore.loadUsername()
            authToken = token
            retryFailures = 0
            snapshot = .connecting(username: username)
            startSessionPollingIfAllowed(using: token)
        } catch {
            sessionLoadError = error.userFacingMessage
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func startSessionPollingIfAllowed(using token: String) {
        guard !reconnectPauseStore.isPaused(for: endpoint) else {
            showPausedState()
            return
        }
        connectionHealth.beginConnection()
        startStream(using: token)
        startUpdateAvailabilityChecks(using: token)
    }

    private func showPausedState() {
        connectionHealth.pause()
        snapshot = snapshot.replacingTelemetryUnavailable(
            note: "Automatic reconnection paused after repeated failures. Choose Reconnect from the actions menu to try again.",
            statusText: "Reconnection paused",
            timestamp: .now
        )
    }

    // Stop all authenticated polling once telemetry has failed repeatedly. A fresh
    // sample or an explicit reconnect starts a new failure streak.
    private func recordStreamFailure() -> Bool {
        retryFailures += 1
        guard retryFailures >= maximumTelemetryFailures else { return true }

        reconnectPauseStore.setPaused(true, for: endpoint)
        activeTelemetryStreamID = nil
        activeUpdateAvailabilityTaskID = nil
        streamTask?.cancel()
        updateAvailabilityTask?.cancel()
        streamTask = nil
        updateAvailabilityTask = nil
        isUpdateAvailable = false
        showPausedState()
        log("Automatic reconnection paused after repeated telemetry failures.")
        return false
    }

    private func startStream(using token: String) {
        streamTask?.cancel()
        let streamID = UUID()
        activeTelemetryStreamID = streamID
        log("Opening telemetry stream.")

        streamTask = Task { [dashboard] in
            while !Task.isCancelled {
                do {
                    try await dashboard.consumeTelemetryStream(
                        token: token,
                        onLog: { message in
                            Task { @MainActor in
                                guard self.isActiveTelemetryStream(id: streamID, token: token) else {
                                    return
                                }

                                self.log(message)
                            }
                        },
                        onConnected: {
                            await MainActor.run {
                                guard self.isActiveTelemetryStream(id: streamID, token: token) else {
                                    return
                                }

                                self.connectionHealth.connected(at: .now)
                                self.snapshot = self.snapshot.replacingTelemetryUnavailable(
                                    note: "Connected to local dashboard. Waiting for the first telemetry event…",
                                    statusText: "Waiting…",
                                    timestamp: .now
                                )
                            }
                        }
                    ) { sample in
                        await MainActor.run {
                            guard self.isActiveTelemetryStream(id: streamID, token: token) else {
                                return
                            }

                            guard TelemetryHistory.accepts(sample) else { return }
                            self.history.append(sample, at: .now)
                            self.retryFailures = 0
                            self.connectionHealth.sampleReceived(at: .now)
                            self.snapshot = .live(sample)
                        }
                    }

                    if !Task.isCancelled {
                        await MainActor.run {
                            guard self.isActiveTelemetryStream(id: streamID, token: token) else {
                                return
                            }

                            self.connectionHealth.reconnecting()
                            self.log("Telemetry stream ended. Waiting to reconnect.")
                            self.snapshot = self.snapshot.replacingTelemetryUnavailable(
                                note: "Waiting for the telemetry stream to resume…",
                                statusText: "Reconnecting…",
                                timestamp: .now
                            )
                        }

                        guard !Task.isCancelled, isActiveTelemetryStream(id: streamID, token: token), recordStreamFailure() else { return }
                        try? await retrySleep(TelemetryConnectionHealth.retryDelay(failures: retryFailures))
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        guard self.isActiveTelemetryStream(id: streamID, token: token) else {
                            return
                        }

                        self.log("Telemetry stream task cancelled.")
                    }
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch DashboardError.unauthorized {
                    await MainActor.run {
                        guard self.isActiveTelemetryStream(id: streamID, token: token) else {
                            return
                        }

                        self.expireDashboardSession(logMessage: "Telemetry stream returned 401.")
                    }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard self.isActiveTelemetryStream(id: streamID, token: token) else {
                            return
                        }

                        self.connectionHealth.reconnecting()
                        self.log("Telemetry stream error: \(error.userFacingMessage)")
                        self.snapshot = self.snapshot.replacingTelemetryUnavailable(
                            note: self.dashboardConnectionFailureMessage(for: error),
                            statusText: "Reconnecting…",
                            timestamp: .now
                        )
                    }

                    guard !Task.isCancelled, isActiveTelemetryStream(id: streamID, token: token), recordStreamFailure() else { return }
                    try? await retrySleep(TelemetryConnectionHealth.retryDelay(failures: retryFailures))
                }
            }
        }
    }

    private func startUpdateAvailabilityChecks(using token: String) {
        updateAvailabilityTask?.cancel()
        let updateAvailabilityTaskID = UUID()
        activeUpdateAvailabilityTaskID = updateAvailabilityTaskID
        isUpdateAvailable = false
        log("Checking system update availability.")

        updateAvailabilityTask = Task { [dashboard] in
            var hasSuccessfulUpdateAvailabilityCheck = false

            while !Task.isCancelled {
                do {
                    let availability = try await dashboard.updateAvailability(token: token)

                    let isStillActive = await MainActor.run {
                        guard self.isActiveUpdateAvailabilityTask(id: updateAvailabilityTaskID, token: token) else {
                            return false
                        }

                        self.isUpdateAvailable = availability.available
                        self.log(
                            availability.available
                                ? "System update is available."
                                : "System is up to date."
                        )
                        return true
                    }

                    if isStillActive {
                        hasSuccessfulUpdateAvailabilityCheck = true
                    }
                } catch is CancellationError {
                    return
                } catch DashboardError.unauthorized {
                    await MainActor.run {
                        guard self.isActiveUpdateAvailabilityTask(id: updateAvailabilityTaskID, token: token) else {
                            return
                        }

                        self.expireDashboardSession(logMessage: "Update availability check returned 401.")
                    }
                    return
                } catch {
                    await MainActor.run {
                        guard self.isActiveUpdateAvailabilityTask(id: updateAvailabilityTaskID, token: token) else {
                            return
                        }

                        self.isUpdateAvailable = false
                        self.log("Update availability check failed: \(error.userFacingMessage)")
                    }
                }

                let delay =
                    hasSuccessfulUpdateAvailabilityCheck
                    ? updateAvailabilityPollInterval
                    : updateAvailabilityRetryInterval
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func isActiveTelemetryStream(id streamID: UUID, token: String) -> Bool {
        authToken == token && activeTelemetryStreamID == streamID
    }

    private func isActiveUpdateAvailabilityTask(id updateAvailabilityTaskID: UUID, token: String) -> Bool {
        authToken == token && activeUpdateAvailabilityTaskID == updateAvailabilityTaskID
    }

    private func dashboardConnectionFailureMessage(for error: Error) -> String {
        DashboardConnectionMessage.message(
            for: error,
            syncAppState: syncAppMonitor.currentState(), endpoint: endpoint
        )
    }

    private func expireDashboardSession(logMessage: String) {
        streamTask?.cancel()
        updateAvailabilityTask?.cancel()
        streamTask = nil
        updateAvailabilityTask = nil
        authToken = nil
        username = ""
        password = ""
        isUpdateAvailable = false
        activeTelemetryStreamID = nil
        activeUpdateAvailabilityTaskID = nil
        removeSavedSession()
        connectionHealth.expire()
        snapshot = .signedOut(note: "Your dashboard session expired. Sign in again.")
        log(logMessage)
    }

    @discardableResult
    private func removeSavedSession() -> Bool {
        do {
            try sessionStore.clearToken()
            sessionStore.clearUsername()
            sessionRemovalError = nil
            return true
        } catch {
            sessionRemovalError = error.userFacingMessage
            log("Failed to remove saved dashboard session: \(error.userFacingMessage)")
            return false
        }
    }

    private func log(_ message: String) {
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)"
        logger.debug("\(line, privacy: .private)")

    }
}
