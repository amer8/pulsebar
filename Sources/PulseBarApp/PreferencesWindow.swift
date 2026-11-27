import AppKit
import Foundation
import PulseBarUI
import SwiftUI

@MainActor
final class PreferencesNavigation: ObservableObject {
    @Published var pane: PreferencesPane = .dashboard
    @Published private(set) var addDeviceRequested = false

    func requestAddDevice() {
        pane = .dashboard
        addDeviceRequested = true
    }

    func beginRequestedSetup(in setup: DGXConnectionSetup) -> Bool {
        guard addDeviceRequested else { return false }
        addDeviceRequested = false
        setup.reset(to: .chooseAlias)
        return true
    }
}

extension MetricsViewModel {
    func preferencesState(port: String, host: String, defaults: UserDefaults = .standard) -> DashboardPreferencesState {
        var state = DashboardPreferencesState(
            deviceName: endpoint.sshHost, accountName: isSignedIn ? (signedInUsername ?? "Signed in") : nil)
        if endpoint.port != DashboardEndpoint.standard.port { state.accountEndpointDetail = "Dashboard port \(endpoint.port)" }
        state.isPortOnlyUpgrade =
            endpoint.sshHost == nil
            && defaults.object(forKey: DashboardEndpoint.preferenceKey) != nil
        state.connectionVerified = isSignedIn
        if endpoint.sshHost == nil && host.isEmpty && port == String(endpoint.port) {
            state.edit = .unconfigured
        } else {
            do {
                let draft = try DashboardEndpoint.parse(port, sshHost: host)
                state.edit = draft == endpoint ? .applied : .pending(draft.profileLabel ?? host)
            } catch { state.edit = .invalid(error.userFacingMessage) }
        }
        state.connectionTitle = connectionHealth.state.rawValue
        state.connectionTone = connectionHealth.state.preferenceTone
        state.isAuthenticating = isAuthenticating
        state.credentialsEntered = canSignIn
        state.isPaused = connectionHealth.state == .paused
        state.removalFailed = sessionRemovalError != nil
        state.sessionLoadIssue = sessionLoadIssue
        if let error = sessionRemovalError {
            let detail = isSignedIn ? "You are still signed in. " : ""
            state.accountNote = PreferencesFeedback(detail + error, tone: .error)
        } else if case .failure(let error) = sessionLoadIssue {
            state.accountNote = PreferencesFeedback(error, tone: .error)
        } else if sessionLoadIssue == nil, let note = snapshot.gpu.note {
            let tone: PreferencesStatusTone = lastSignInFailed ? .error : state.connectionTone
            state.accountNote = PreferencesFeedback(note, tone: tone)
        }
        return state
    }
}

struct PulseBarPreferencesView: View {
    @ObservedObject var sessions: DeviceSessions
    let navigation: PreferencesNavigation
    var onContentSizeChange: @MainActor @Sendable (CGSize) -> Void = { _ in }

    var body: some View {
        DevicePreferencesForm(
            sessions: sessions, viewModel: sessions.managed, navigation: navigation, onContentSizeChange: onContentSizeChange
        )
        .id(sessions.managed.endpoint)
    }
}

private struct DevicePreferencesForm: View {
    @ObservedObject var sessions: DeviceSessions
    @ObservedObject var viewModel: MetricsViewModel
    @ObservedObject var navigation: PreferencesNavigation
    let onContentSizeChange: @MainActor @Sendable (CGSize) -> Void
    @State private var hostText: String
    @State private var portText: String
    @StateObject private var setup = DGXConnectionSetup()
    @State private var refreshConnections = 0

    init(
        sessions: DeviceSessions, viewModel: MetricsViewModel, navigation: PreferencesNavigation,
        onContentSizeChange: @escaping @MainActor @Sendable (CGSize) -> Void
    ) {
        self.sessions = sessions
        self.viewModel = viewModel
        self.navigation = navigation
        self.onContentSizeChange = onContentSizeChange
        _hostText = State(initialValue: viewModel.endpoint.sshHost ?? "")
        _portText = State(initialValue: String(viewModel.endpoint.port))
    }

    var body: some View {
        DashboardPreferencesContent(
            port: draftBinding($portText), sshHost: draftBinding($hostText), username: $viewModel.username, password: $viewModel.password,
            pane: $navigation.pane, state: presentation, actions: actions,
            onContentSizeChange: onContentSizeChange
        ) {
            LoginItemPreferencesView()
            MenuBarPreferencesView()
        }
        .task(id: navigation.addDeviceRequested) {
            if navigation.beginRequestedSetup(in: setup) {
                hostText = ""
                portText = String(viewModel.endpoint.sshHost == nil ? viewModel.endpoint.port : DashboardEndpoint.standard.port)
                viewModel.password = ""
            }
        }
        .task(id: isChoosingAlias ? refreshConnections : nil) {
            if isChoosingAlias { await setup.loadAliases() }
        }
        .onDisappear { restoreAppliedFields() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isChoosingAlias { refreshConnections += 1 }
        }
    }

    private var isChoosingAlias: Bool { navigation.pane == .dashboard && setup.step == .chooseAlias }

    private var presentation: DashboardPreferencesState {
        sessions.preferencesState(port: portText, host: hostText, setup: setup)
    }

    private func draftBinding(_ binding: Binding<String>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue },
            set: { value in
                guard value != binding.wrappedValue else { return }
                setup.reset(to: setup.step == .chooseAlias ? .chooseAlias : .choose)
                viewModel.password = ""
                binding.wrappedValue = value
            })
    }

    private func connect(expected: String? = nil) {
        guard !viewModel.isAuthenticating, let target = try? DashboardEndpoint.parse(portText, sshHost: hostText) else { return }
        if setup.step == .choose, target != viewModel.endpoint && !presentation.canApply { return }
        if setup.step == .chooseAlias, presentation.availableAliases?.contains(hostText) != true { return }
        sessions.beginVerification(of: target)
        setup.connect(target, expected: expected) { checked in
            guard sessions.managed === viewModel, checked.matches(portText: portText, sshHost: hostText) else { return }
            sessions.didVerify(checked)
            hostText = sessions.managed.endpoint.sshHost ?? ""
        }
    }

    private var actions: DashboardPreferencesActions {
        var actions = DashboardPreferencesActions()
        actions.addDevice = navigation.requestAddDevice
        actions.selectDevice = { alias in
            guard sessions.manage(alias) else { return }
            setup.reset()
            hostText = sessions.managed.endpoint.sshHost ?? ""
            portText = String(sessions.managed.endpoint.port)
        }
        actions.connect = { connect() }
        actions.cancelSetup = restoreAppliedFields
        actions.openSync = { Task { await PulseBarNavigation.openNVIDIASync() } }
        actions.verify = { connect(expected: $0) }
        actions.discardEdits = { restoreAppliedFields() }
        actions.signIn = { if presentation.canSignIn { _ = viewModel.signIn(portText: portText, sshHost: hostText) } }
        actions.signOut = {
            if sessions.managed === viewModel, presentation.canUseProfile { viewModel.signOut() }
        }
        actions.reconnect = { if presentation.canUseProfile && presentation.isPaused { viewModel.refresh() } }
        actions.retrySessionLoad = { if presentation.canUseProfile { viewModel.retrySavedSession() } }
        return actions
    }

    private func restoreAppliedFields() {
        portText = String(viewModel.endpoint.port)
        hostText = viewModel.endpoint.sshHost ?? ""
        setup.reset()
    }

}

@MainActor
enum PulseBarNavigation {
    private static let navigation = PreferencesNavigation()
    private static var preferencesWindow: NSWindow?
    private static var preferencesSizing: PreferencesWindowSizing?

    static func openNVIDIASync(
        using launch: @MainActor () async -> Bool = DashboardSetupActions.openSync,
        onFailure: @MainActor () -> Void = showSyncLaunchError
    ) async {
        if !(await launch()) { onFailure() }
    }

    private static func showSyncLaunchError() {
        let alert = NSAlert()
        alert.messageText = "Couldn’t open NVIDIA Sync"
        alert.informativeText = "Check that a copy from NVIDIA is installed in Applications, then try again."
        if NSApp.activationPolicy() == .prohibited { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func openPreferences(sessions: DeviceSessions, pane: PreferencesPane = .dashboard, addingDevice: Bool = false) {
        if addingDevice {
            navigation.requestAddDevice()
        } else {
            navigation.pane = pane
        }
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
                    sessions: sessions, navigation: navigation,
                    onContentSizeChange: { [weak sizing] size in sizing?.contentSizeDidChange(size) }
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
                sessions: sessions, navigation: navigation, onContentSizeChange: { size in preferencesSizing?.contentSizeDidChange(size) }
            )
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

}
