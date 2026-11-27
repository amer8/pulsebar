import Foundation
import PulseBarUI

@MainActor
final class DGXConnectionSetup: ObservableObject {
    @Published private(set) var step: DGXSetupStep = .choose
    @Published private(set) var busy = false
    @Published private(set) var feedback: PreferencesFeedback?
    @Published private(set) var savedAliases: [String]?
    private var challenge: (endpoint: DashboardEndpoint, origin: DGXSetupStep)?
    private var task: Task<Void, Never>?
    private let probe: (DashboardEndpoint) async throws -> Bool
    private let fingerprint: (String, String?) async throws -> String

    init(
        probe: @escaping (DashboardEndpoint) async throws -> Bool = { try await DashboardClient(endpoint: $0).checkConnection() },
        fingerprint: @escaping (String, String?) async throws -> String = {
            try await SSHHostEnrollment(host: $0).presentedFingerprint(confirming: $1)
        }
    ) {
        self.probe = probe
        self.fingerprint = fingerprint
    }

    func reset(to step: DGXSetupStep = .choose) {
        task?.cancel()
        if step != .chooseAlias || self.step != .chooseAlias { savedAliases = nil }
        self.step = step
        feedback = nil
        challenge = nil
        busy = false
    }

    func loadAliases(using read: @escaping @Sendable () -> [String] = { SavedSSHConnections().aliases() }) async {
        guard step == .chooseAlias else { return }
        let aliases = await Task.detached(priority: .userInitiated, operation: read).value
        guard step == .chooseAlias, !Task.isCancelled else { return }
        savedAliases = aliases
    }

    private func showError(_ error: Error) {
        feedback = PreferencesFeedback(error.userFacingMessage, tone: .error)
    }

    @discardableResult
    func connect(_ target: DashboardEndpoint, expected: String? = nil, onConnected: @escaping (DashboardEndpoint) -> Void) -> Task<
        Void, Never
    >? {
        guard !busy, let host = target.sshHost else { return nil }
        let origin: DGXSetupStep
        if let expected {
            guard let challenge, challenge.endpoint == target, case .verify(let displayed) = step, expected == displayed else { return nil }
            origin = challenge.origin
        } else {
            guard step == .choose || (step == .chooseAlias && savedAliases?.contains(host) == true) else { return nil }
            origin = step
        }
        busy = true
        feedback = nil
        let operation = Task {
            defer { if !Task.isCancelled { busy = false } }
            do {
                if let expected { _ = try await fingerprint(host, expected) }
                try Task.checkCancellation()
                guard try await probe(target) else {
                    throw DashboardError.server(
                        "SSH connected, but the dashboard did not respond on port \(target.port). Check the DGX Dashboard port and try again."
                    )
                }
                try Task.checkCancellation()
                step = .choose
                challenge = nil
                onConnected(target)
                feedback = PreferencesFeedback("Connected to \(host) over verified SSH.", tone: .success)
            } catch DashboardError.unknownSSHHostKey where expected == nil {
                do {
                    try Task.checkCancellation()
                    let presented = try await fingerprint(host, nil)
                    try Task.checkCancellation()
                    challenge = (target, origin)
                    step = .verify(presented)
                } catch {
                    if !Task.isCancelled {
                        step = origin
                        challenge = nil
                        showError(error)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    step = origin
                    challenge = nil
                    showError(error)
                }
            }
        }
        task = operation
        return operation
    }
}
