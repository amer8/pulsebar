import AppKit
import Foundation
import OSLog
import PulseBarUI
import Security
import SwiftUI

private var dashboardBaseURL: URL { DashboardEndpoint.current.url }
private var dashboardLocalEndpoint: String { DashboardEndpoint.current.address }
private var manualSSHTunnelCommand: String { DashboardEndpoint.current.tunnelCommand }
private let updateAvailabilityPollInterval: Duration = .seconds(3_600)
private let updateAvailabilityRetryInterval: Duration = .seconds(30)

@MainActor
final class MetricsViewModel: ObservableObject {
    @Published private(set) var connectionHealth = TelemetryConnectionHealth()
    @Published private(set) var snapshot: MetricsSnapshot
    @Published private(set) var debugMessages: [String] = []
    @Published private(set) var isUpdateAvailable = false
    @Published private(set) var endpoint = DashboardEndpoint.current
    @Published var username: String
    @Published var password = ""
    @Published private(set) var isAuthenticating = false

    private var dashboard: DashboardClient
    private let syncAppMonitor: NVIDIASyncAppMonitor
    private var sessionStore: any DashboardSessionStoring
    private let logger = Logger(subsystem: "PulseBar", category: "Dashboard")
    private var healthTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var retryFailures = 0
    private var authToken: String?
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
        dashboard: DashboardClient? = nil,
        sessionStore: (any DashboardSessionStoring)? = nil
    ) {
        let endpoint = DashboardEndpoint.current
        let dashboard = dashboard ?? DashboardClient(baseURL: endpoint.url)
        let sessionStore = sessionStore ?? DashboardSessionStore(endpoint: endpoint)
        let username = sessionStore.loadUsername()
        let authToken = sessionStore.loadToken()

        self.dashboard = dashboard
        self.syncAppMonitor = syncAppMonitor
        self.sessionStore = sessionStore
        self.authToken = authToken
        self.endpoint = endpoint

        if authToken != nil {
            self.username = username
            self.snapshot = .connecting(username: username)
        } else {
            self.username = ""
            self.snapshot = .signedOut()
            sessionStore.clearUsername()
        }

        if let authToken {
            connectionHealth.beginConnection()
            log("Loaded saved dashboard session for '\(username)'.")
            startStream(using: authToken)
            startUpdateAvailabilityChecks(using: authToken)
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
                self?.refresh()
            }
        }
    }

    func checkFreshness(at date: Date) {
        guard let authToken, connectionHealth.markStale(at: date) else { return }
        snapshot = snapshot.replacingTelemetryUnavailable(note: "Telemetry is stale. Reconnecting…", statusText: "Stale", timestamp: date)
        startStream(using: authToken)
    }

    deinit {
        healthTask?.cancel()
        wakeTask?.cancel()
        streamTask?.cancel()
        updateAvailabilityTask?.cancel()
    }

    func refresh() {
        guard let authToken else {
            snapshot = .signedOut(note: "Sign in to the local dashboard to stream metrics.")
            return
        }

        retryFailures = 0
        connectionHealth.reconnecting()
        snapshot = snapshot.replacingTelemetryUnavailable(
            note: "Reconnecting to the local dashboard…",
            statusText: "Reconnecting…",
            timestamp: .now
        )
        startStream(using: authToken)
        startUpdateAvailabilityChecks(using: authToken)
    }

    func signIn() {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !password.isEmpty else {
            snapshot = .signedOut(note: "Enter your dashboard username and password.")
            return
        }

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
        Task { [dashboard] in
            do {
                let token = try await dashboard.login(username: trimmedUsername, password: password)

                try await MainActor.run {
                    try self.sessionStore.saveToken(token)
                    self.sessionStore.saveUsername(trimmedUsername)
                    self.isAuthenticating = false
                    self.password = ""
                    self.username = trimmedUsername
                    self.authToken = token
                    self.snapshot = .connecting(username: trimmedUsername)
                    self.log("Login succeeded. Saved token to Keychain.")
                    self.startStream(using: token)
                    self.startUpdateAvailabilityChecks(using: token)
                }
            } catch {
                await MainActor.run {
                    let message = self.dashboardConnectionFailureMessage(for: error)
                    self.isAuthenticating = false
                    self.password = ""
                    self.username = trimmedUsername
                    self.authToken = nil
                    self.activeTelemetryStreamID = nil
                    self.activeUpdateAvailabilityTaskID = nil
                    self.isUpdateAvailable = false
                    self.sessionStore.clearUsername()
                    self.sessionStore.clearToken()
                    self.connectionHealth = TelemetryConnectionHealth()
                    self.snapshot = .signedOut(note: message)
                    self.log("Sign-in failed: \(message)")
                }
            }
        }
    }

    func signOut() {
        streamTask?.cancel()
        updateAvailabilityTask?.cancel()
        streamTask = nil
        updateAvailabilityTask = nil
        activeTelemetryStreamID = nil
        activeUpdateAvailabilityTaskID = nil
        authToken = nil
        username = ""
        password = ""
        isUpdateAvailable = false
        sessionStore.clearUsername()
        sessionStore.clearToken()
        connectionHealth = TelemetryConnectionHealth()
        snapshot = .signedOut(note: "Signed out. Sign in again to resume metrics.")
        log("Signed out and cleared saved username and token.")
    }

    func configureEndpoint(_ target: DashboardEndpoint) {
        guard target != endpoint, !isAuthenticating else { return }
        streamTask?.cancel()
        updateAvailabilityTask?.cancel()
        activeTelemetryStreamID = nil
        activeUpdateAvailabilityTaskID = nil
        endpoint = target
        target.save()
        dashboard = DashboardClient(baseURL: target.url)
        sessionStore = DashboardSessionStore(endpoint: target)
        authToken = sessionStore.loadToken()
        username = sessionStore.loadUsername()
        password = ""
        isUpdateAvailable = false
        retryFailures = 0
        connectionHealth = TelemetryConnectionHealth()
        snapshot = authToken == nil ? .signedOut() : .connecting(username: username)
        if let authToken {
            connectionHealth.beginConnection()
            startStream(using: authToken)
            startUpdateAvailabilityChecks(using: authToken)
        }
    }

    func testConnection() async -> String {
        let target = endpoint
        var request = URLRequest(url: target.url)
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                return "A service responded, but the dashboard page was unavailable."
            }
            return "Dashboard page is reachable at \(target.address). Sign in to verify telemetry."
        } catch { return DashboardConnectionMessage.message(for: error, syncAppState: syncAppMonitor.currentState(), endpoint: target) }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
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

                            let usedGiB = max((sample.memoryTotalMB - sample.memoryAvailableMB) / 1024, 0)
                            let totalGiB = max(sample.memoryTotalMB / 1024, 0).rounded(.up)
                            self.log(
                                "Received telemetry sample: GPU \(Int(sample.gpuUtilizationPercent.rounded()))%, memory \(MetricNumberFormat.usedMemoryGiBString(usedGiB)) / \(MetricNumberFormat.wholeNumberString(totalGiB)) GB."
                            )
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

                        retryFailures += 1
                        try? await Task.sleep(for: TelemetryConnectionHealth.retryDelay(failures: retryFailures))
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        guard self.isActiveTelemetryStream(id: streamID, token: token) else {
                            return
                        }

                        self.log("Telemetry stream task cancelled.")
                    }
                    return
                } catch DashboardError.unauthorized {
                    await MainActor.run {
                        guard self.isActiveTelemetryStream(id: streamID, token: token) else {
                            return
                        }

                        self.expireDashboardSession(logMessage: "Telemetry stream returned 401. Cleared saved session.")
                    }
                    return
                } catch {
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

                    retryFailures += 1
                    try? await Task.sleep(for: TelemetryConnectionHealth.retryDelay(failures: retryFailures))
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

                        self.expireDashboardSession(logMessage: "Update availability check returned 401. Cleared saved session.")
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
        sessionStore.clearUsername()
        sessionStore.clearToken()
        connectionHealth.expire()
        snapshot = .signedOut(note: "Your dashboard session expired. Sign in again.")
        log(logMessage)
    }

    private func log(_ message: String) {
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)"
        logger.debug("\(line, privacy: .private)")
        debugMessages.append(line)

        if debugMessages.count > 8 {
            debugMessages.removeFirst(debugMessages.count - 8)
        }
    }
}

@MainActor
struct MetricsMenuView: View {
    @ObservedObject var viewModel: MetricsViewModel
    @ObservedObject private var sparkle = SparkleController.shared
    var menuState: MetricsMenuState {
        MetricsMenuState(viewModel: viewModel)
    }

    var body: some View {
        let menuState = self.menuState
        Group {
            Section {
                Label(menuState.connectionHealth.state.rawValue, systemImage: "network")
                if let date = menuState.connectionHealth.lastSampleAt {
                    Text("Last sample: \(date.formatted(date: .omitted, time: .standard))")
                }
                if menuState.isSignedIn { Button("Reconnect") { viewModel.refresh() } }
            }
            Section {
                MetricMenuRow(
                    systemImage: "memorychip",
                    title: "RAM",
                    value: menuState.snapshot.memory.menuDetailText
                )
                MetricMenuRow(
                    systemImage: "cpu.fill",
                    title: "GPU",
                    value: menuState.snapshot.gpu.menuDetailText
                )
            }

            if let note = menuState.snapshot.gpu.note {
                Section {
                    Text(note)
                        .foregroundStyle(.secondary)
                }
            }

            if !menuState.isSignedIn {
                Section {
                    Text("Sign in from Preferences to connect to the local dashboard.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    PulseBarNavigation.openPreferences(viewModel: viewModel)
                } label: {
                    Label("Preferences…", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)

                Button {
                    PulseBarNavigation.openDashboard()
                } label: {
                    Label("Open Dashboard", systemImage: "safari")
                }

                if sparkle.canCheckForUpdates {
                    Button {
                        sparkle.checkForUpdates()
                    } label: {
                        Label(
                            sparkle.isUpdateReady ? "Update ready, restart now?" : "Check for Updates…",
                            systemImage: "arrow.down.circle"
                        )
                    }
                }

                if menuState.isUpdateAvailable {
                    Label("System update available", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                }
            }

            Section {
                Button {
                    viewModel.quit()
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

@MainActor
struct MetricsMenuState {
    let connectionHealth: TelemetryConnectionHealth
    let snapshot: MetricsSnapshot
    let isSignedIn: Bool
    let isUpdateAvailable: Bool

    init(viewModel: MetricsViewModel) {
        connectionHealth = viewModel.connectionHealth
        snapshot = viewModel.snapshot
        isSignedIn = viewModel.isSignedIn
        isUpdateAvailable = viewModel.isUpdateAvailable
    }
}

private struct MetricMenuRow: View {
    let systemImage: String
    let title: String
    let value: String

    var body: some View {
        Label("\(title): \(value)", systemImage: systemImage)
            .monospacedDigit()
    }
}

struct MetricsSnapshot {
    let memory: MemorySnapshot
    let gpu: GPUSnapshot
    let timestamp: Date

    var menuBarTitle: String {
        "RAM \(memory.percentText) GPU \(gpu.menuBarText)"
    }

    static func signedOut(note: String? = nil) -> MetricsSnapshot {
        MetricsSnapshot(
            memory: MemorySnapshot(statusText: "Unavailable"),
            gpu: GPUSnapshot(
                deviceName: "GPU",
                utilizationPercent: nil,
                statusText: "Unavailable",
                note: note
            ),
            timestamp: .now
        )
    }

    static func connecting(username: String) -> MetricsSnapshot {
        let prefix = username.isEmpty ? "Connecting to local dashboard…" : "Connecting to local dashboard as \(username)…"

        return MetricsSnapshot(
            memory: MemorySnapshot(statusText: "Connecting…"),
            gpu: GPUSnapshot(
                deviceName: "GPU",
                utilizationPercent: nil,
                statusText: "Connecting…",
                note: prefix
            ),
            timestamp: .now
        )
    }

    static func live(_ sample: TelemetrySample) -> MetricsSnapshot {
        let usedGiB = max((sample.memoryTotalMB - sample.memoryAvailableMB) / 1024, 0)
        let totalGiB = max(sample.memoryTotalMB / 1024, 0).rounded(.up)
        let percentUsed = totalGiB > 0 ? (usedGiB / totalGiB) * 100 : 0

        return MetricsSnapshot(
            memory: MemorySnapshot(
                usedGiB: usedGiB,
                totalGiB: totalGiB,
                percentUsed: percentUsed,
                statusText: nil
            ),
            gpu: GPUSnapshot(
                deviceName: "GPU",
                utilizationPercent: sample.gpuUtilizationPercent,
                statusText: nil,
                note: nil
            ),
            timestamp: .now
        )
    }

    func replacingTelemetryUnavailable(note: String?, statusText: String, timestamp: Date) -> MetricsSnapshot {
        MetricsSnapshot(
            memory: MemorySnapshot(statusText: statusText),
            gpu: GPUSnapshot(
                deviceName: gpu.deviceName,
                utilizationPercent: nil,
                statusText: statusText,
                note: note
            ),
            timestamp: timestamp
        )
    }
}

struct MemorySnapshot {
    let usedGiB: Double?
    let totalGiB: Double?
    let percentUsed: Double?
    let statusText: String?

    init(
        usedGiB: Double? = nil,
        totalGiB: Double? = nil,
        percentUsed: Double? = nil,
        statusText: String? = nil
    ) {
        self.usedGiB = usedGiB
        self.totalGiB = totalGiB
        self.percentUsed = percentUsed
        self.statusText = statusText
    }

    var percentText: String {
        guard let percentUsed else {
            return "--"
        }

        return "\(Int(percentUsed.rounded()))%"
    }

    var detailText: String {
        guard let usedGiB, let totalGiB else {
            return statusText ?? "Unavailable"
        }

        let usedText = MetricNumberFormat.usedMemoryGiBString(usedGiB)
        let totalText = MetricNumberFormat.wholeNumberString(totalGiB)
        return "\(percentText) (\(usedText) / \(totalText) GB)"
    }

    var menuDetailText: String {
        guard usedGiB != nil, totalGiB != nil else {
            return "--"
        }

        return detailText
    }
}

struct GPUSnapshot {
    let deviceName: String?
    let utilizationPercent: Double?
    let statusText: String?
    let note: String?

    var menuBarText: String {
        guard let utilizationPercent else {
            return "--"
        }

        return "\(Int(utilizationPercent.rounded()))%"
    }

    var detailText: String {
        guard let utilizationPercent else {
            return statusText ?? "Unavailable"
        }

        return "\(Int(utilizationPercent.rounded()))%"
    }

    var menuDetailText: String {
        guard utilizationPercent != nil else {
            return "--"
        }

        return detailText
    }

    var summaryText: String {
        guard let utilizationPercent else {
            return deviceName ?? "Unavailable"
        }

        if let deviceName, !deviceName.isEmpty {
            return "\(deviceName) \(Int(utilizationPercent.rounded()))%"
        }

        return "\(Int(utilizationPercent.rounded()))%"
    }
}

private struct TelemetryPayload: Decodable {
    let telemetryForGPUs: [TelemetrySample]

    private enum CodingKeys: String, CodingKey {
        case telemetryForGPUs = "TelemetryForGPUs"
    }
}

struct TelemetrySample: Decodable, Sendable {
    let gpuUtilizationPercent: Double
    let memoryTotalMB: Double
    let memoryAvailableMB: Double

    private enum CodingKeys: String, CodingKey {
        case gpuUtilizationPercent = "percentage_utilization"
        case memoryTotalMB = "memory_total_in_mb"
        case memoryAvailableMB = "memory_available_in_mb"
        case memoryTotalKiB = "memory_total_in_kib"
        case memoryAvailableKiB = "memory_available_in_kib"
    }
}

extension TelemetrySample {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gpuUtilizationPercent = try container.decode(Double.self, forKey: .gpuUtilizationPercent)
        // Current dashboards report KiB; normalize to the units used by existing views.
        // Require a complete pair so mixed payloads cannot silently combine different units.
        if container.contains(.memoryTotalKiB) || container.contains(.memoryAvailableKiB) {
            memoryTotalMB = try container.decode(Double.self, forKey: .memoryTotalKiB) / 1024
            memoryAvailableMB = try container.decode(Double.self, forKey: .memoryAvailableKiB) / 1024
        } else {
            memoryTotalMB = try container.decode(Double.self, forKey: .memoryTotalMB)
            memoryAvailableMB = try container.decode(Double.self, forKey: .memoryAvailableMB)
        }
    }
}

enum TelemetryParser {
    static func firstSample(from data: Data) throws -> TelemetrySample {
        let payload: TelemetryPayload
        do {
            payload = try JSONDecoder().decode(TelemetryPayload.self, from: data)
        } catch DecodingError.keyNotFound(let key, _) {
            throw DashboardError.server("Dashboard telemetry is missing '\(key.stringValue)'.")
        } catch DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context) {
            let field = context.codingPath.last?.stringValue ?? "payload"
            throw DashboardError.server("Dashboard telemetry has an invalid value for '\(field)'.")
        } catch DecodingError.dataCorrupted {
            throw DashboardError.server("Dashboard telemetry contains invalid JSON or numeric data.")
        }
        guard let sample = payload.telemetryForGPUs.first else {
            throw DashboardError.missingTelemetry
        }

        guard sample.gpuUtilizationPercent.isFinite, (0...100).contains(sample.gpuUtilizationPercent),
            sample.memoryTotalMB.isFinite, sample.memoryTotalMB > 0,
            sample.memoryAvailableMB.isFinite, (0...sample.memoryTotalMB).contains(sample.memoryAvailableMB)
        else { throw DashboardError.server("The dashboard returned invalid telemetry.") }
        return sample
    }
}

private struct LoginResponse: Decodable {
    let token: String
}

private struct DashboardErrorResponse: Decodable {
    let error: String
}

struct UpdateAvailability: Decodable, Sendable {
    let available: Bool
}

enum NVIDIASyncAppState: Equatable, Sendable {
    case running
    case notRunning
}

struct NVIDIASyncAppMonitor: Sendable {
    let currentState: @MainActor @Sendable () -> NVIDIASyncAppState

    static let live = NVIDIASyncAppMonitor {
        NSWorkspace.shared.runningApplications.contains { app in
            matches(
                bundleIdentifier: app.bundleIdentifier,
                localizedName: app.localizedName,
                bundleName: app.bundleURL?.deletingPathExtension().lastPathComponent
            )
        } ? .running : .notRunning
    }

    static func matches(bundleIdentifier: String?, localizedName: String?, bundleName: String?) -> Bool {
        [bundleIdentifier, localizedName, bundleName]
            .compactMap(normalizedIdentifier)
            .contains { identifier in
                identifier == "nvidiasync"
                    || identifier == "nvidiasyncapp"
                    || identifier.contains("nvidiasync")
            }
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        value?
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
    }
}

enum DashboardConnectionMessage {
    static func message(for error: Error, syncAppState: NVIDIASyncAppState, endpoint: DashboardEndpoint = .standard) -> String {
        guard error.isLocalDashboardConnectivityError else {
            return error.userFacingMessage
        }

        switch syncAppState {
        case .running:
            return "NVIDIA Sync is running. Open DGX Dashboard, or keep a manual SSH tunnel forwarding \(endpoint.address)."
        case .notRunning:
            return "Expose DGX Dashboard at \(endpoint.address) with NVIDIA Sync or a manual SSH tunnel: \(endpoint.tunnelCommand)"
        }
    }
}

enum DashboardError: LocalizedError {
    case invalidResponse
    case unauthorized
    case loginFailed
    case missingTelemetry
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The dashboard returned an unexpected response."
        case .unauthorized:
            return "The dashboard rejected the current session."
        case .loginFailed:
            return "Login failed. Check your dashboard credentials."
        case .missingTelemetry:
            return "The telemetry stream did not include GPU data."
        case .server(let message):
            return message
        }
    }
}

struct DashboardClient: Sendable {
    private let session: URLSession
    private let baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:11000")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func login(username: String, password: String) async throws -> String {
        var request = URLRequest(url: endpoint("/api/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DashboardError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw DashboardError.loginFailed
            }

            if let errorResponse = try? JSONDecoder().decode(DashboardErrorResponse.self, from: data) {
                throw DashboardError.server(errorResponse.error)
            }

            throw DashboardError.loginFailed
        }

        let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)
        return loginResponse.token
    }

    func updateAvailability(token: String) async throws -> UpdateAvailability {
        var request = URLRequest(url: endpoint("/api/v1/updates/available"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DashboardError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw DashboardError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            if let errorResponse = try? JSONDecoder().decode(DashboardErrorResponse.self, from: data) {
                throw DashboardError.server(errorResponse.error)
            }

            throw DashboardError.server("Unable to check system update availability.")
        }

        return try JSONDecoder().decode(UpdateAvailability.self, from: data)
    }

    func consumeTelemetryStream(
        token: String,
        onLog: @escaping @Sendable (String) -> Void = { _ in },
        onConnected: @escaping @Sendable () async -> Void = {},
        onSample: @escaping @Sendable (TelemetrySample) async -> Void
    ) async throws {
        var request = URLRequest(url: endpoint("/api/v1/gpu_telemetry/stream"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        onLog("Requesting /api/v1/gpu_telemetry/stream.")

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DashboardError.invalidResponse
        }

        onLog("Telemetry stream responded with HTTP \(httpResponse.statusCode).")

        if httpResponse.statusCode == 401 {
            throw DashboardError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            throw DashboardError.server("Unable to open the telemetry stream.")
        }

        await onConnected()
        onLog("Telemetry stream is open. Waiting for SSE events.")

        var eventName = ""
        var dataLines: [String] = []
        var lineBuffer: [UInt8] = []
        var previousWasCarriageReturn = false

        for try await byte in bytes {
            if Task.isCancelled {
                throw CancellationError()
            }

            if byte == 0x0D {
                let line = decodeSSELine(from: lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)
                previousWasCarriageReturn = true

                if line.isEmpty {
                    try await handleEvent(
                        name: eventName,
                        dataLines: dataLines,
                        onLog: onLog,
                        onSample: onSample
                    )
                    eventName = ""
                    dataLines.removeAll(keepingCapacity: true)
                    continue
                }

                if line.hasPrefix(":") {
                    continue
                }

                let (field, value) = parseSSEField(line)

                switch field {
                case "event":
                    eventName = value
                case "data":
                    dataLines.append(value)
                default:
                    break
                }
            } else if byte == 0x0A {
                if previousWasCarriageReturn {
                    previousWasCarriageReturn = false
                    continue
                }

                let line = decodeSSELine(from: lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)

                if line.isEmpty {
                    try await handleEvent(
                        name: eventName,
                        dataLines: dataLines,
                        onLog: onLog,
                        onSample: onSample
                    )
                    eventName = ""
                    dataLines.removeAll(keepingCapacity: true)
                    continue
                }

                if line.hasPrefix(":") {
                    continue
                }

                let (field, value) = parseSSEField(line)

                switch field {
                case "event":
                    eventName = value
                case "data":
                    dataLines.append(value)
                default:
                    break
                }
            } else {
                previousWasCarriageReturn = false
                lineBuffer.append(byte)
            }
        }
    }

    private func handleEvent(
        name: String,
        dataLines: [String],
        onLog: @escaping @Sendable (String) -> Void,
        onSample: @escaping @Sendable (TelemetrySample) async -> Void
    ) async throws {
        guard !dataLines.isEmpty else {
            return
        }

        let data = Data(dataLines.joined(separator: "\n").utf8)

        switch name {
        case "gpu_telemetry":
            onLog("Received gpu_telemetry event.")
            let sample = try TelemetryParser.firstSample(from: data)
            await onSample(sample)

        case "error":
            onLog("Received error event from telemetry stream.")
            if let errorResponse = try? JSONDecoder().decode(DashboardErrorResponse.self, from: data) {
                throw DashboardError.server(errorResponse.error)
            }
            throw DashboardError.server("The telemetry stream returned an error.")

        default:
            if !name.isEmpty {
                onLog("Ignored SSE event '\(name)'.")
            }
            break
        }
    }

    private func endpoint(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private func decodeSSELine(from bytes: [UInt8]) -> String {
        var bytes = bytes

        if bytes.last == 0x0D {
            bytes.removeLast()
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    private func parseSSEField(_ line: String) -> (field: String, value: String) {
        guard let separator = line.firstIndex(of: ":") else {
            return (line, "")
        }

        let field = String(line[..<separator])
        var value = String(line[line.index(after: separator)...])

        if value.first == " " {
            value.removeFirst()
        }

        return (field, value)
    }
}

private enum SessionStoreError: LocalizedError {
    case keychainSaveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainSaveFailed(let status):
            let statusMessage = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "PulseBar could not save the dashboard session token to Keychain: \(statusMessage)."
        }
    }
}

@MainActor
protocol DashboardSessionStoring {
    func loadUsername() -> String
    func saveUsername(_ username: String)
    func clearUsername()
    func loadToken() -> String?
    func saveToken(_ token: String) throws
    func clearToken()
}

struct DashboardSessionStore: DashboardSessionStoring {
    private let endpoint: DashboardEndpoint
    private let defaults: UserDefaults
    private let keychainService = "PulseBar.Dashboard"
    private var usernameKey: String { endpoint.usernameKey }
    private var keychainAccount: String { endpoint.sessionAccount }
    init(endpoint: DashboardEndpoint = .current, defaults: UserDefaults = .standard) {
        self.endpoint = endpoint
        self.defaults = defaults
    }

    func loadUsername() -> String {
        defaults.string(forKey: usernameKey) ?? ""
    }

    func saveUsername(_ username: String) {
        defaults.set(username, forKey: usernameKey)
    }

    func clearUsername() {
        defaults.removeObject(forKey: usernameKey)
    }

    func loadToken() -> String? {
        var query = keychainQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    func saveToken(_ token: String) throws {
        let tokenData = Data(token.utf8)
        let updateAttributes = [
            kSecValueData as String: tokenData
        ]

        let updateStatus = SecItemUpdate(keychainQuery as CFDictionary, updateAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            throw SessionStoreError.keychainSaveFailed(updateStatus)
        }

        var query = keychainQuery
        query[kSecValueData as String] = tokenData

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SessionStoreError.keychainSaveFailed(addStatus)
        }
    }

    func clearToken() {
        SecItemDelete(keychainQuery as CFDictionary)
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }
}

enum MetricNumberFormat {
    static func usedMemoryGiBString(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        decimalString(value, fractionDigits: 2, locale: locale)
    }

    static func wholeNumberString(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        decimalString(value, fractionDigits: 0, locale: locale)
    }

    private static func decimalString(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.usesGroupingSeparator = false

        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

extension StringProtocol {
    fileprivate var trimmed: String {
        String(self).trimmingCharacters(in: .whitespaces)
    }
}

extension Error {
    fileprivate var userFacingMessage: String {
        if let localizedError = self as? LocalizedError,
            let description = localizedError.errorDescription
        {
            return description
        }

        return localizedDescription
    }

    fileprivate var isLocalDashboardConnectivityError: Bool {
        guard let urlError = self as? URLError else {
            return false
        }

        switch urlError.code {
        case .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .timedOut:
            return true
        default:
            return false
        }
    }
}

struct PulseBarPreferencesView: View {
    @ObservedObject var viewModel: MetricsViewModel
    var onContentSizeChange: @MainActor @Sendable (CGSize) -> Void = { _ in }
    @State private var portText = String(DashboardEndpoint.current.port)
    @State private var feedback: PreferencesFeedback?
    @State private var checking = false

    var body: some View {
        DashboardPreferencesContent(
            port: $portText, username: $viewModel.username, password: $viewModel.password,
            state: presentation, actions: actions, additionalCardsFirst: true,
            onContentSizeChange: onContentSizeChange
        ) {
            WelcomePreferencesView()
            LoginItemPreferencesView()
        }
    }

    private var presentation: DashboardPreferencesState {
        var state = DashboardPreferencesState(
            endpointAddress: viewModel.endpoint.address,
            accountName: viewModel.isSignedIn ? (viewModel.username.isEmpty ? "dashboard" : viewModel.username) : nil
        )
        state.connectionTitle = viewModel.connectionHealth.state.rawValue
        switch viewModel.connectionHealth.state {
        case .live: state.connectionTone = .success
        case .stale, .reconnecting, .expired: state.connectionTone = .warning
        default: state.connectionTone = .neutral
        }
        state.isAuthenticating = viewModel.isAuthenticating
        state.isChecking = checking
        state.canApplyPort = (try? DashboardEndpoint.parse(portText)) != viewModel.endpoint
        state.canTestConnection = !state.canApplyPort
        state.canSignIn = viewModel.canSignIn
        state.feedback = feedback
        state.accountNote = viewModel.snapshot.gpu.note
        return state
    }

    private var actions: DashboardPreferencesActions {
        var actions = DashboardPreferencesActions()
        actions.applyPort = {
            do {
                let endpoint = try DashboardEndpoint.parse(portText)
                viewModel.configureEndpoint(endpoint)
                portText = String(endpoint.port)
                feedback = nil
            } catch { feedback = PreferencesFeedback(error.userFacingMessage, tone: .error) }
        }
        actions.testConnection = {
            checking = true
            Task {
                feedback = PreferencesFeedback(await viewModel.testConnection())
                checking = false
            }
        }
        actions.openSync = {
            feedback =
                DashboardSetupActions.openSync()
                ? PreferencesFeedback("Opened NVIDIA Sync.")
                : PreferencesFeedback("NVIDIA Sync was not found in Applications.", tone: .error)
        }
        actions.copyTunnel = {
            DashboardSetupActions.copyTunnel(viewModel.endpoint)
            feedback = PreferencesFeedback("SSH tunnel command copied.", tone: .success)
        }
        actions.signIn = { viewModel.signIn() }
        actions.signOut = { viewModel.signOut() }
        return actions
    }
}

@MainActor
enum PulseBarNavigation {
    private static var preferencesWindow: NSWindow?
    private static var preferencesSizing: PreferencesWindowSizing?

    static func openPreferences(viewModel: MetricsViewModel) {
        if NSApplication.shared.activationPolicy() == .prohibited {
            NSApplication.shared.setActivationPolicy(.accessory)
        }

        if preferencesWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
                let bounds = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: bounds.midX - window.frame.width / 2, y: bounds.midY - window.frame.height / 2))
            }
            let sizing = PreferencesWindowSizing(window: window)
            let hostingController = NSHostingController(
                rootView: PulseBarPreferencesView(
                    viewModel: viewModel, onContentSizeChange: { [weak sizing] size in sizing?.contentSizeDidChange(size) }
                )
            )
            hostingController.sizingOptions = []
            window.contentViewController = hostingController
            window.standardWindowButton(.zoomButton)?.isEnabled = false

            preferencesSizing = sizing
            preferencesWindow = window
        } else if let window = preferencesWindow,
            let hostingController = window.contentViewController as? NSHostingController<PulseBarPreferencesView>
        {
            hostingController.rootView = PulseBarPreferencesView(
                viewModel: viewModel, onContentSizeChange: { size in preferencesSizing?.contentSizeDidChange(size) })
        }

        preferencesWindow?.title = "PulseBar Preferences"
        preferencesWindow?.titleVisibility = .visible
        preferencesWindow?.titlebarAppearsTransparent = false
        preferencesWindow?.contentView?.layoutSubtreeIfNeeded()
        preferencesSizing?.fitContent()
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        preferencesWindow?.orderFrontRegardless()
        preferencesWindow?.makeKey()
    }

    static func openDashboard() {
        NSWorkspace.shared.open(dashboardBaseURL)
    }
}
