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
    let message: String
    let tone: PreferencesStatusTone

    public init(_ message: String, tone: PreferencesStatusTone = .neutral) {
        self.message = message
        self.tone = tone
    }
}

public struct DashboardPreferencesState {
    public var endpointAddress: String
    public var accountName: String?
    public var connectionTitle = "Signed out"
    public var connectionTone: PreferencesStatusTone = .neutral
    public var isAuthenticating = false
    public var isChecking = false
    public var canApplyPort = false
    public var canTestConnection = true
    public var canSignIn = false
    public var feedback: PreferencesFeedback?
    public var accountNote: String?

    public init(endpointAddress: String, accountName: String? = nil) {
        self.endpointAddress = endpointAddress
        self.accountName = accountName
    }
}

public struct DashboardPreferencesActions {
    public var applyPort: () -> Void = {}
    public var testConnection: () -> Void = {}
    public var openSync: () -> Void = {}
    public var copyTunnel: () -> Void = {}
    public var signIn: () -> Void = {}
    public var signOut: () -> Void = {}

    public init() {}
}

// Shared by the app and the README renderer so previews use the shipping layout.
public struct DashboardPreferencesContent: View {
    @Binding private var port: String
    @Binding private var username: String
    @Binding private var password: String
    @Binding private var showDiagnostics: Bool
    private let state: DashboardPreferencesState
    private let actions: DashboardPreferencesActions
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    public init(
        port: Binding<String>, username: Binding<String>, password: Binding<String>, showDiagnostics: Binding<Bool>,
        state: DashboardPreferencesState, actions: DashboardPreferencesActions
    ) {
        _port = port
        _username = username
        _password = password
        _showDiagnostics = showDiagnostics
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                connectionCard
                accountCard
                diagnosticsCard
            }
            .padding(24)
        }
        .font(.system(size: 13))
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if state.accountName == nil { focusedField = username.isEmpty ? .username : .password }
        }
        .onChange(of: state.accountName) { account in
            if account == nil { focusedField = .username } else { focusedField = nil }
        }
    }

    private var connectionCard: some View {
        card {
            HStack {
                sectionLabel("Connection", symbol: "network")
                Spacer()
                Label(state.connectionTitle, systemImage: state.connectionTone.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(state.connectionTone.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(state.connectionTone.color.opacity(0.1), in: Capsule())
            }

            HStack(spacing: 8) {
                Text("Local port").foregroundStyle(.secondary)
                Spacer()
                TextField("11000", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 80)
                    .disabled(state.isAuthenticating)
                    .onSubmit { if state.canApplyPort && !state.isAuthenticating { actions.applyPort() } }
                    .accessibilityLabel("Local dashboard port")
                Button("Apply", action: actions.applyPort)
                    .disabled(!state.canApplyPort || state.isAuthenticating)
            }

            HStack(spacing: 12) {
                Text("http://\(state.endpointAddress)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button(action: actions.testConnection) {
                    Label(state.isChecking ? "Testing…" : "Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(!state.canTestConnection || state.isChecking || state.isAuthenticating)
                .help(state.canApplyPort ? "Apply the new port before testing." : "Check whether the local dashboard page is reachable.")
            }

            if let feedback = state.feedback { feedbackRow(feedback) }

            Divider()
            HStack(spacing: 20) {
                Button(action: actions.openSync) { Label("Open NVIDIA Sync", systemImage: "arrow.up.forward.app") }
                Button(action: actions.copyTunnel) { Label("Copy SSH Command", systemImage: "doc.on.doc") }
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
    }

    private var accountCard: some View {
        card {
            sectionLabel("Dashboard account", symbol: "person.crop.circle")
            if let account = state.accountName {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Signed in as \(account)").fontWeight(.medium)
                        Text("Session saved securely in Keychain.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign Out", action: actions.signOut)
                }
            } else {
                Text("Sign in with your DGX Dashboard credentials.")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Username").foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                        TextField("Username", text: $username).focused($focusedField, equals: .username)
                    }
                    GridRow {
                        Text("Password").foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                        SecureField("Password", text: $password)
                            .focused($focusedField, equals: .password)
                            .onSubmit { if state.canSignIn { actions.signIn() } }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(state.isAuthenticating)
                HStack {
                    Label("Session stored in Keychain", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(state.isAuthenticating ? "Signing In…" : "Sign In", action: actions.signIn)
                        .buttonStyle(.borderedProminent)
                        .disabled(!state.canSignIn)
                }
            }
            if let note = state.accountNote {
                feedbackRow(PreferencesFeedback(note, tone: state.accountName == nil ? .neutral : .warning))
            }
        }
    }

    private var diagnosticsCard: some View {
        card {
            Toggle(isOn: $showDiagnostics) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Show diagnostics in menu").fontWeight(.medium)
                    Text("Include recent dashboard connection logs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
    }

    private func feedbackRow(_ feedback: PreferencesFeedback) -> some View {
        Label(feedback.message, systemImage: feedback.tone.symbol)
            .font(.caption)
            .foregroundStyle(feedback.tone.color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5) }
    }
}
