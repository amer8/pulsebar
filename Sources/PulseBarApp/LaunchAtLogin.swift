import Foundation
import PulseBarUI
import ServiceManagement
import SwiftUI

enum LoginItemStatus: String {
    case disabled = "Disabled"
    case enabled = "Enabled"
    case requiresApproval = "Approval required in System Settings"
    case unavailable = "Available in a packaged app in Applications"
    var requested: Bool { self == .enabled || self == .requiresApproval }
}

@MainActor
protocol LoginItemServing {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) async throws
}

@MainActor
struct SystemLoginItemService: LoginItemServing {
    var status: LoginItemStatus {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    func setEnabled(_ enabled: Bool) async throws {
        if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
    }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?
    private let service: any LoginItemServing
    init(service: any LoginItemServing = SystemLoginItemService()) {
        self.service = service
        status = service.status
    }
    func refresh() { status = service.status }
    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating, status != .unavailable else { return }
        isUpdating = true
        errorMessage = nil
        do { try await service.setEnabled(enabled) } catch {
            errorMessage = "Could not change launch at login: \(error.localizedDescription)"
        }
        status = service.status
        isUpdating = false
    }
}

struct LoginItemPreferencesView: View {
    @StateObject private var controller = LoginItemController()
    var body: some View {
        StartupPreferencesContent(
            isEnabled: Binding(
                get: { controller.status.requested }, set: { enabled in Task { await controller.setEnabled(enabled) } }
            ),
            status: controller.status.rawValue, isUpdating: controller.isUpdating, isUnavailable: controller.status == .unavailable,
            requiresApproval: controller.status == .requiresApproval, errorMessage: controller.errorMessage,
            openSettings: { SMAppService.openSystemSettingsLoginItems() }
        )
        .onAppear { controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refresh() }
    }
}

struct WelcomePreferencesView: View {
    @AppStorage("PulseBar.HasSeenWelcome") private var hasSeenWelcome = false
    var body: some View {
        WelcomePreferencesContent(
            isVisible: !hasSeenWelcome, endpointAddress: DashboardEndpoint.current.address, dismiss: { hasSeenWelcome = true }
        )
    }
}
