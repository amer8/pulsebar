import SwiftUI

public struct StartupPreferencesContent: View {
    @Binding private var isEnabled: Bool
    private let status: String
    private let isUpdating: Bool
    private let isUnavailable: Bool
    private let requiresApproval: Bool
    private let errorMessage: String?
    private let openSettings: () -> Void

    public init(
        isEnabled: Binding<Bool>, status: String, isUpdating: Bool = false, isUnavailable: Bool = false,
        requiresApproval: Bool = false, errorMessage: String? = nil, openSettings: @escaping () -> Void
    ) {
        _isEnabled = isEnabled
        self.status = status
        self.isUpdating = isUpdating
        self.isUnavailable = isUnavailable
        self.requiresApproval = requiresApproval
        self.errorMessage = errorMessage
        self.openSettings = openSettings
    }

    public var body: some View {
        DashboardPreferencesCard {
            Label("Startup", systemImage: "power").fontWeight(.semibold)
            Toggle(isOn: $isEnabled) { Text("Launch PulseBar at login").frame(maxWidth: .infinity, alignment: .leading) }
                .toggleStyle(.switch).controlSize(.small).disabled(isUpdating || isUnavailable)
            Text(status).font(.caption).foregroundStyle(.secondary)
            if requiresApproval { Button("Open Login Items Settings", action: openSettings) }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

public struct WelcomePreferencesContent: View {
    private let isVisible: Bool
    private let endpointAddress: String
    private let dismiss: () -> Void

    public init(isVisible: Bool, endpointAddress: String, dismiss: @escaping () -> Void) {
        self.isVisible = isVisible
        self.endpointAddress = endpointAddress
        self.dismiss = dismiss
    }

    public var body: some View {
        if isVisible {
            DashboardPreferencesCard {
                Label("Welcome to PulseBar", systemImage: "waveform.path.ecg").fontWeight(.semibold)
                Text("Connect your DGX Dashboard at \(endpointAddress) using NVIDIA Sync or an SSH tunnel, then sign in below.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Label("Session stored securely in Keychain", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Got It", action: dismiss)
                }
            }
        }
    }
}
