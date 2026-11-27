import AppKit
import SwiftUI

public enum PreferencesStatusTone {
    case neutral, success, warning, error

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
    var symbol: String {
        switch self {
        case .neutral: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }
}

public struct PreferencesFeedback {
    public let message: String
    public let tone: PreferencesStatusTone

    public init(_ message: String, tone: PreferencesStatusTone = .neutral) {
        self.message = message
        self.tone = tone
    }
}

public enum PreferencesPane: String, CaseIterable {
    case dashboard = "Devices"
    case general = "General"
}

public enum DashboardProfileEdit: Equatable {
    case unconfigured
    case invalid(String)
    case pending(String)
    case applied
}

public enum DGXSetupStep: Equatable {
    case choose, chooseAlias
    case verify(String)
}

public enum SavedSessionLoadIssue: Equatable {
    case permissionRequired
    case failure(String)
}

public struct DashboardPreferencesState {
    public static let defaultDashboardPort = 11000
    public var devices: [DeviceOption] = []
    public var availableAliases: [String]?
    public var setupStep: DGXSetupStep = .choose
    public var connectionVerified = false
    public var showsAccount: Bool {
        setupStep == .choose && edit == .applied && (connectionVerified || accountName != nil || sessionLoadIssue != nil || removalFailed)
    }
    var showsSavedSessionRecovery: Bool { showsAccount && accountName == nil && (sessionLoadIssue != nil || removalFailed) }
    var showsSignInForm: Bool { showsAccount && accountName == nil && connectionVerified && !showsSavedSessionRecovery }

    public let deviceName: String?
    var accountTitle: String { showsSignInForm ? "Sign in to DGX Dashboard" : "DGX Dashboard account" }
    public var accountHeading: String {
        deviceName.map { "\(accountTitle) on \($0)" } ?? accountTitle
    }
    public var restoreSessionTitle: String {
        deviceName.map { "Restore Saved Session for \($0)" } ?? "Restore Saved Session"
    }
    public let accountName: String?
    public var accountEndpointDetail: String?
    public var edit: DashboardProfileEdit = .unconfigured
    public var connectionTitle = "Signed out"
    public var connectionTone: PreferencesStatusTone = .neutral
    public var isAuthenticating = false
    public var isChecking = false
    public var isPortOnlyUpgrade = false
    public var credentialsEntered = false
    public var isPaused = false
    public var removalFailed = false
    public var sessionLoadIssue: SavedSessionLoadIssue?
    public var feedback: PreferencesFeedback?
    public var accountNote: PreferencesFeedback?

    public init(deviceName: String?, accountName: String? = nil) {
        self.deviceName = deviceName
        self.accountName = accountName
    }

    public var canApply: Bool {
        if case .pending = edit { return !isAuthenticating && !removalFailed }
        return false
    }
    public var canUseProfile: Bool { setupStep == .choose && edit == .applied && !isAuthenticating }
    public var canSignIn: Bool { canUseProfile && !isChecking && showsSignInForm && credentialsEntered }
}

public struct DashboardPreferencesActions {
    public var selectDevice: @MainActor @Sendable (String) -> Void = { _ in }
    public var addDevice: () -> Void = {}
    public var connect: () -> Void = {}
    public var cancelSetup: () -> Void = {}
    public var openSync: () -> Void = {}
    public var verify: (String) -> Void = { _ in }
    public var signIn: () -> Void = {}
    public var signOut: () -> Void = {}
    public var discardEdits: () -> Void = {}
    public var reconnect: () -> Void = {}
    public var retrySessionLoad: () -> Void = {}

    public init() {}
}

// Shared by the app and the README renderer so previews use the shipping layout.
public struct DashboardPreferencesContent<AdditionalCards: View>: View {
    @Binding private var sshHost: String
    @Binding private var port: String
    @Binding private var username: String
    @Binding private var password: String
    private let state: DashboardPreferencesState
    private let actions: DashboardPreferencesActions
    private let additionalCards: AdditionalCards
    @Binding private var pane: PreferencesPane
    @State private var showsKeychainHelp = false
    @State private var expectedFingerprint = ""
    @State private var fingerprintHelp = false
    private let onContentSizeChange: @MainActor @Sendable (CGSize) -> Void
    @ScaledMetric(relativeTo: .body) private var portFieldWidth = 80.0
    @ScaledMetric(relativeTo: .body) private var accountLabelWidth = 72.0
    @FocusState private var focusedField: Field?

    private enum Field { case fingerprint, username, password }

    public init(
        port: Binding<String>, sshHost: Binding<String>, username: Binding<String>, password: Binding<String>,
        pane: Binding<PreferencesPane>, state: DashboardPreferencesState, actions: DashboardPreferencesActions,
        onContentSizeChange: @escaping @MainActor @Sendable (CGSize) -> Void = { _ in },
        @ViewBuilder additionalCards: () -> AdditionalCards
    ) {
        _sshHost = sshHost
        _port = port
        _username = username
        _password = password
        _pane = pane
        self.state = state
        self.actions = actions
        self.additionalCards = additionalCards()
        self.onContentSizeChange = onContentSizeChange
    }

    public var body: some View {
        ScrollView {
            PreferencesContentMeasurement(onSizeChange: onContentSizeChange) {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Preferences", selection: $pane) {
                        ForEach(PreferencesPane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .center)
                    switch pane {
                    case .dashboard:
                        connectionCard
                    case .general: additionalCards
                    }
                }
                .padding(24)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusFirstField() }
        .onChange(of: pane) { _ in focusFirstField() }
        .onChange(of: state.setupStep) { _ in
            expectedFingerprint = ""
            fingerprintHelp = false
            focusFirstField()
        }
        .onChange(of: state.showsSignInForm) { _ in focusFirstField() }
    }

    private func focusFirstField() {
        guard pane == .dashboard else {
            focusedField = nil
            return
        }
        if case .verify = state.setupStep {
            focusedField = .fingerprint
        } else if state.showsSignInForm {
            focusedField = username.isEmpty ? .username : .password
        } else {
            focusedField = nil
        }
    }

    var devicePicker: DevicePicker {
        DevicePicker(
            devices: state.devices, selection: Binding(get: { state.deviceName ?? "" }, set: actions.selectDevice),
            label: "SSH host alias", addDevice: actions.addDevice)
    }

    private var connectionCard: some View {
        card {
            switch state.setupStep {
            case .choose:
                HStack {
                    sectionLabel(state.edit == .applied ? "SSH host alias" : "Connect to your device", symbol: "desktopcomputer")
                    Spacer()
                    if state.edit == .applied, state.accountName != nil { statusLabel }
                }
                HStack {
                    devicePicker
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    if state.isChecking {
                        testingIndicator
                    } else if !state.devices.isEmpty {
                        Button(state.showsAccount ? "Test" : "Connect", action: actions.connect)
                            .buttonStyle(.bordered)
                            .fixedSize()
                            .help("Check the dashboard connection over SSH.")
                            .disabled(!(state.canApply || state.canUseProfile))
                    }
                }
                .disabled(state.isAuthenticating || state.isChecking)
                if state.edit == .applied, state.deviceName != nil {
                    Divider()
                    accountHeader
                    if state.showsAccount { accountSection }
                }
                if state.isPortOnlyUpgrade {
                    Text("Choose your device and sign in once to upgrade your previous local-port connection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if state.isPaused { Button("Reconnect", action: actions.reconnect).disabled(!state.canUseProfile) }
            case .chooseAlias:
                sectionLabel("Choose a device", symbol: "desktopcomputer")
                if let aliases = state.availableAliases {
                    if aliases.isEmpty {
                        Text("No additional devices found in your SSH configuration.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Choose a saved SSH alias to verify its Dashboard connection.").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Looking for SSH aliases…").controlSize(.small)
                }
                addDeviceOptions
                if state.availableAliases?.isEmpty == false {
                    Divider()
                    deviceSettings
                    if case .invalid(let reason) = state.edit, !sshHost.isEmpty {
                        feedbackRow(PreferencesFeedback(reason, tone: .error))
                    }
                }
                HStack {
                    Button("Cancel", action: actions.cancelSetup)
                    Spacer()
                    if state.isChecking { testingIndicator }
                }
            case .verify(let presented):
                sectionLabel("Verify your device", symbol: "lock.shield")
                Text("Compare the key presented by \(sshHost) with the SHA256 fingerprint from the device’s console or its administrator.")
                Text(presented).font(.callout.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Where do I find this?", isExpanded: $fingerprintHelp) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ask your administrator, or run this on the device’s console and paste the matching SHA256 value.")
                        Text("cat /etc/ssh/ssh_host_*_key.pub | ssh-keygen -E sha256 -lf -")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                TextField("Fingerprint from your trusted source", text: $expectedFingerprint).focused($focusedField, equals: .fingerprint)
                    .textFieldStyle(.roundedBorder)
                let entered = expectedFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
                if !entered.isEmpty && entered != presented {
                    feedbackRow(PreferencesFeedback("The fingerprints do not match.", tone: .error))
                }
                HStack {
                    Button("Cancel", action: actions.cancelSetup)
                    Spacer()
                    if state.isChecking {
                        testingIndicator
                    } else {
                        Button("Verify and Connect") { actions.verify(entered) }
                            .buttonStyle(.borderedProminent).disabled(entered != presented)
                    }
                }
            }
            if let feedback = state.feedback { feedbackRow(feedback) }
            if state.setupStep == .choose, state.deviceName != nil {
                Divider()
                deviceSettings
                if case .invalid(let reason) = state.edit { feedbackRow(PreferencesFeedback(reason, tone: .error)) }
                if state.edit != .applied {
                    Button("Discard Edits", action: actions.discardEdits).buttonStyle(.link)
                    if state.removalFailed {
                        Text("Discard edits and retry signing out before switching connections.").font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder var addDeviceOptions: some View {
        ForEach(state.availableAliases ?? [], id: \.self) { alias in
            Button {
                sshHost = alias
                actions.connect()
            } label: {
                Label {
                    Text(verbatim: alias)
                } icon: {
                    Image(systemName: "desktopcomputer")
                }
            }
            .disabled(state.isChecking || state.isAuthenticating)
        }
        Button("Set up a device in NVIDIA Sync…", action: actions.openSync)
            .buttonStyle(.link)
            .disabled(state.isChecking)
    }

    private var statusLabel: some View {
        Label(state.connectionTitle, systemImage: state.connectionTone.symbol)
            .font(.caption).foregroundStyle(state.connectionTone.color)
    }

    private var testingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Testing connection…").font(.callout).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private var deviceSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(.headline)
            HStack {
                Text("DGX Dashboard port")
                Spacer(minLength: 6)
                if Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) == DashboardPreferencesState.defaultDashboardPort {
                    Text("Default").font(.caption).foregroundStyle(.secondary)
                }
                TextField(String(DashboardPreferencesState.defaultDashboardPort), text: $port)
                    .textFieldStyle(.roundedBorder).frame(width: portFieldWidth)
                    .accessibilityLabel("Dashboard port on the device")
            }
            if state.showsSavedSessionRecovery, let device = state.deviceName {
                SavedSessionRemoval(device: device, retry: state.removalFailed, remove: actions.signOut)
                    .id(device)
                    .disabled(!state.canUseProfile)
            }
        }
        .disabled(state.isAuthenticating || state.isChecking)
    }

    private var accountHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.accountTitle).font(.headline)
                if let alias = state.deviceName {
                    Text(verbatim: alias).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.accountHeading)
            Spacer(minLength: 6)
            if state.accountName == nil { statusLabel }
        }
    }

    @ViewBuilder private var accountSection: some View {
        if let account = state.accountName {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: account).font(.headline)
                    if let detail = state.accountEndpointDetail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(state.removalFailed ? "Retry Sign Out" : "Sign Out", action: actions.signOut).fixedSize().disabled(
                    !state.canUseProfile
                )
                .help("Remove this device’s saved dashboard session from Keychain.")
            }
        }
        if state.showsSignInForm {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Username").foregroundStyle(.secondary).frame(width: accountLabelWidth, alignment: .leading)
                    TextField("Username", text: $username).focused($focusedField, equals: .username)
                }
                GridRow {
                    Text("Password").foregroundStyle(.secondary).frame(width: accountLabelWidth, alignment: .leading)
                    SecureField("Password", text: $password)
                        .focused($focusedField, equals: .password)
                        .onSubmit { if state.canSignIn { actions.signIn() } }
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(!state.canUseProfile || state.removalFailed)
            HStack {
                Spacer()
                Button(state.isAuthenticating ? "Signing In…" : "Sign In", action: actions.signIn)
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canSignIn)
            }
        }
        let needsPermission = state.sessionLoadIssue == .permissionRequired && !state.removalFailed
        if needsPermission {
            Label("Allow Keychain access to resume telemetry with your saved sign-in.", systemImage: "lock")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let note = state.accountNote {
            feedbackRow(note)
        }
        if state.showsSavedSessionRecovery && !state.removalFailed {
            Button("Restore Saved Session", action: actions.retrySessionLoad)
                .accessibilityLabel(state.restoreSessionTitle)
                .disabled(!state.canUseProfile)
        }
        if needsPermission {
            DisclosureGroup("Why is permission needed?", isExpanded: $showsKeychainHelp) {
                Text(
                    "PulseBar keeps this device’s dashboard sign-in in Keychain. macOS may ask for your Mac login password to allow access."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }.font(.callout)
        }
    }

    private func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).fontWeight(.semibold)
    }

    private func feedbackRow(_ feedback: PreferencesFeedback) -> some View {
        Label(feedback.message, systemImage: feedback.tone.symbol)
            .font(.caption)
            .foregroundStyle(feedback.tone.color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        DashboardPreferencesCard(content: content)
    }
}

struct SavedSessionRemovalConfirmation {
    var requestedDevice: String?

    mutating func confirm(for device: String, remove: () -> Void) {
        guard requestedDevice == device else { return }
        requestedDevice = nil
        remove()
    }
}

private struct SavedSessionRemoval: View {
    let device: String
    let retry: Bool
    let remove: () -> Void
    @State private var confirmation = SavedSessionRemovalConfirmation()

    var body: some View {
        if confirmation.requestedDevice == device {
            VStack(alignment: .leading, spacing: 7) {
                Text("Remove the saved session for \(device)?").fontWeight(.semibold)
                Text("You’ll need to sign in again to see telemetry from this device.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { confirmation.requestedDevice = nil }
                    Button("Remove", role: .destructive) {
                        confirmation.confirm(for: device, remove: remove)
                    }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        } else {
            Button(retry ? "Retry Removing Session…" : "Remove Saved Session…") { confirmation.requestedDevice = device }
                .help("Remove this device’s saved dashboard session from Keychain.")
        }
    }
}

private struct PreferencesContentMeasurement: Layout {
    let onSizeChange: @MainActor @Sendable (CGSize) -> Void

    func makeCache(subviews: Subviews) -> CGSize { .zero }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CGSize) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CGSize) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        if cache != bounds.size {
            cache = bounds.size
            Task { @MainActor [onSizeChange, size = bounds.size] in onSizeChange(size) }
        }
    }
}

public struct DashboardPreferencesCard<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5) }
    }
}
