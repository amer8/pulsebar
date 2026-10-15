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
public struct DashboardPreferencesContent<AdditionalCards: View>: View {
    @Binding private var port: String
    @Binding private var username: String
    @Binding private var password: String
    private let state: DashboardPreferencesState
    private let actions: DashboardPreferencesActions
    private let additionalCards: AdditionalCards
    private let additionalCardsFirst: Bool
    private let onContentSizeChange: @MainActor @Sendable (CGSize) -> Void
    @ScaledMetric(relativeTo: .body) private var portFieldWidth = 80.0
    @ScaledMetric(relativeTo: .body) private var accountLabelWidth = 72.0
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    public init(
        port: Binding<String>, username: Binding<String>, password: Binding<String>,
        state: DashboardPreferencesState, actions: DashboardPreferencesActions, additionalCardsFirst: Bool = false,
        onContentSizeChange: @escaping @MainActor @Sendable (CGSize) -> Void = { _ in },
        @ViewBuilder additionalCards: () -> AdditionalCards
    ) {
        _port = port
        _username = username
        _password = password
        self.state = state
        self.actions = actions
        self.additionalCards = additionalCards()
        self.additionalCardsFirst = additionalCardsFirst
        self.onContentSizeChange = onContentSizeChange
    }

    public init(
        port: Binding<String>, username: Binding<String>, password: Binding<String>,
        state: DashboardPreferencesState, actions: DashboardPreferencesActions,
        onContentSizeChange: @escaping @MainActor @Sendable (CGSize) -> Void = { _ in }
    ) where AdditionalCards == EmptyView {
        self.init(
            port: port, username: username, password: password,
            state: state, actions: actions, onContentSizeChange: onContentSizeChange, additionalCards: { EmptyView() }
        )
    }

    public var body: some View {
        ScrollView {
            PreferencesContentMeasurement(onSizeChange: onContentSizeChange) {
                VStack(alignment: .leading, spacing: 16) {
                    if additionalCardsFirst { additionalCards }
                    connectionCard
                    accountCard
                    if !additionalCardsFirst { additionalCards }
                }
                .padding(24)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                    .font(.caption.weight(.medium))
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
                    .frame(width: portFieldWidth)
                    .disabled(state.isAuthenticating)
                    .onSubmit { if state.canApplyPort && !state.isAuthenticating { actions.applyPort() } }
                    .accessibilityLabel("Local dashboard port")
                Button("Apply", action: actions.applyPort)
                    .disabled(!state.canApplyPort || state.isAuthenticating)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    endpointLabel
                    Spacer(minLength: 0)
                    testConnectionButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    endpointLabel
                    testConnectionButton
                }
            }

            if let feedback = state.feedback { feedbackRow(feedback) }

            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { setupButtons }
                VStack(alignment: .leading, spacing: 12) { setupButtons }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    private var endpointLabel: some View {
        Text("http://\(state.endpointAddress)")
            .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }

    private var testConnectionButton: some View {
        Button(action: actions.testConnection) {
            Label(state.isChecking ? "Testing…" : "Test Connection", systemImage: "antenna.radiowaves.left.and.right")
        }
        .disabled(!state.canTestConnection || state.isChecking || state.isAuthenticating)
        .help(state.canApplyPort ? "Apply the new port before testing." : "Check whether the local dashboard page is reachable.")
    }

    @ViewBuilder private var setupButtons: some View {
        Button(action: actions.openSync) { Label("Open NVIDIA Sync", systemImage: "arrow.up.forward.app") }
        Button(action: actions.copyTunnel) { Label("Copy SSH Command", systemImage: "doc.on.doc") }
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
