import Combine
import Foundation
import PulseBarUI

/// Owns the collectors for the lifetime of the app. Neither picker owns a collector.
@MainActor
final class DeviceSessions: ObservableObject {
    private static let profilesKey = "PulseBar.Dashboard.Devices"
    private static let displayKey = "PulseBar.Dashboard.DisplayedHost"

    private let defaults: UserDefaults?
    private let makeModel: (DashboardEndpoint) -> MetricsViewModel
    private var models: [MetricsViewModel]
    private var observations: [DashboardEndpoint: AnyCancellable] = [:]
    @Published private(set) var displayed: MetricsViewModel
    @Published private(set) var managed: MetricsViewModel
    private(set) var verifiedEndpoints: Set<DashboardEndpoint> = []

    init(
        defaults: UserDefaults? = .standard,
        makeModel: @escaping (DashboardEndpoint) -> MetricsViewModel = { MetricsViewModel(endpoint: $0) }
    ) {
        self.defaults = defaults
        self.makeModel = makeModel
        var aliases = Set<String>()
        let profiles = defaults?.array(forKey: Self.profilesKey) ?? []
        var endpoints = profiles.compactMap { record -> DashboardEndpoint? in
            guard let fields = record as? [String: Any], let host = fields["host"] as? String, let port = fields["port"] as? Int,
                let endpoint = try? DashboardEndpoint(port: port, sshHost: host), aliases.insert(host.lowercased()).inserted
            else { return nil }
            return endpoint
        }
        if endpoints.isEmpty { endpoints = [defaults.map(DashboardEndpoint.saved(in:)) ?? .standard] }
        let models = endpoints.map(makeModel)
        self.models = models
        let selected = models.first { $0.endpoint.sshHost == defaults?.string(forKey: Self.displayKey) } ?? models[0]
        displayed = selected
        managed = selected
        for model in models { observe(model) }
    }

    private func observe(_ model: MetricsViewModel) {
        observations[model.endpoint] = model.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    private func model(for alias: String) -> MetricsViewModel? {
        models.first { $0.endpoint.sshHost?.caseInsensitiveCompare(alias) == .orderedSame }
    }

    var devices: [DeviceOption] {
        models.compactMap { model in
            guard let alias = model.endpoint.sshHost else { return nil }
            let state = model.connectionHealth.state
            return DeviceOption(alias: alias, status: state.rawValue, tone: state.preferenceTone, username: model.signedInUsername)
        }
    }

    func preferencesState(port: String, host: String, setup: DGXConnectionSetup) -> DashboardPreferencesState {
        var state = managed.preferencesState(port: port, host: host)
        state.devices = devices
        if setup.step == .chooseAlias, let aliases = setup.savedAliases {
            state.availableAliases = aliases.filter { model(for: $0) == nil }
        }
        state.setupStep = setup.step
        state.connectionVerified = state.connectionVerified || verifiedEndpoints.contains(managed.endpoint)
        state.isChecking = setup.busy
        state.feedback = setup.feedback
        return state
    }

    func display(_ alias: String) {
        guard let model = model(for: alias), displayed !== model else { return }
        displayed = model
        defaults?.set(model.endpoint.sshHost, forKey: Self.displayKey)
    }

    @discardableResult
    func manage(_ alias: String) -> Bool {
        guard let model = model(for: alias) else { return false }
        if managed !== model {
            managed.password = ""
            managed = model
        }
        return true
    }

    func beginVerification(of endpoint: DashboardEndpoint) {
        if verifiedEndpoints.remove(endpoint) != nil { objectWillChange.send() }
    }

    /// Called after the SSH probe succeeds. Rechecking an existing endpoint reuses its running stream.
    func didVerify(_ endpoint: DashboardEndpoint) {
        guard let alias = endpoint.sshHost else { return }
        if let existing = model(for: alias), existing.endpoint.port == endpoint.port {
            verifiedEndpoints.insert(existing.endpoint)
            _ = manage(alias)
            objectWillChange.send()
            return
        }
        let newModel = makeModel(endpoint)
        if let index = models.firstIndex(where: {
            $0.endpoint.sshHost == nil || $0.endpoint.sshHost?.caseInsensitiveCompare(alias) == .orderedSame
        }) {
            let old = models[index]
            observations.removeValue(forKey: old.endpoint)
            old.stopMonitoring()
            verifiedEndpoints.remove(old.endpoint)
            models[index] = newModel
            if displayed === old { displayed = newModel }
        } else {
            models.append(newModel)
        }
        observe(newModel)
        verifiedEndpoints.insert(endpoint)
        _ = manage(alias)
        let profiles = models.compactMap { model -> [String: Any]? in
            guard let host = model.endpoint.sshHost else { return nil }
            return ["host": host, "port": model.endpoint.port]
        }
        defaults?.set(profiles, forKey: Self.profilesKey)
        defaults?.set(displayed.endpoint.sshHost, forKey: Self.displayKey)
    }
}

extension TelemetryConnectionHealth.State {
    var preferenceTone: PreferencesStatusTone {
        switch self {
        case .live: .success
        case .stale, .reconnecting, .paused, .expired: .warning
        case .signedOut, .signingIn, .connecting, .waiting: .neutral
        }
    }
}
