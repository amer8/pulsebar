import AppKit
import Foundation
import PulseBarUI
import SwiftUI

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
            MenuBarPreferencesView()
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
        case .stale, .reconnecting, .paused, .expired: state.connectionTone = .warning
        default: state.connectionTone = .neutral
        }
        state.isAuthenticating = viewModel.isAuthenticating
        state.isChecking = checking
        state.canApplyPort = (try? DashboardEndpoint.parse(portText)) != viewModel.endpoint && viewModel.sessionRemovalError == nil
        state.canTestConnection = !state.canApplyPort
        state.canSignIn = viewModel.canSignIn
        state.feedback = feedback
        state.accountNote = viewModel.sessionRemovalError ?? viewModel.sessionLoadError ?? viewModel.snapshot.gpu.note
        state.canRetrySessionRemoval = !viewModel.isSignedIn && viewModel.sessionRemovalError != nil
        state.canRetrySessionLoad = !viewModel.isSignedIn && viewModel.sessionLoadError != nil && viewModel.sessionRemovalError == nil
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
        actions.signIn = { _ = viewModel.signIn() }
        actions.signOut = { viewModel.signOut() }
        actions.retrySessionLoad = { viewModel.retrySavedSession() }
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
        NSWorkspace.shared.open(DashboardEndpoint.current.url)
    }
}
