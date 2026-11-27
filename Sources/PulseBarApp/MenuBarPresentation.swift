import PulseBarUI

struct MenuBarPresentation {
    let state: TelemetryConnectionHealth.State
    let snapshot: MetricsSnapshot
    var display: MenuBarDisplay = .both
    var showsAvailableUpdate = false

    var connectionSymbol: String? {
        switch state {
        case .live: nil
        case .reconnecting, .connecting: "arrow.clockwise"
        case .stale, .paused, .expired: "exclamationmark.triangle.fill"
        case .signedOut: MenuBarDisplay.iconSymbol
        case .signingIn, .waiting: "hourglass"
        }
    }

    private var readings: String {
        switch display {
        case .both: snapshot.menuBarTitle
        case .memory: "RAM \(snapshot.memory.percentText)"
        case .gpu: "GPU \(snapshot.gpu.menuBarText)"
        case .icon: "PulseBar"
        }
    }

    var accessibilityLabel: String {
        let connection: String
        switch state {
        case .paused: connection = "Reconnection paused. Open PulseBar to reconnect."
        case .expired: connection = "Dashboard session expired. Open PulseBar to sign in."
        case .live: connection = "\(readings). \(state.rawValue)."
        default: connection = state.rawValue
        }
        return showsAvailableUpdate ? connection + " DGX system update available." : connection
    }

    var fallbackTitle: String {
        let title = state == .live ? readings : state.rawValue
        return showsAvailableUpdate ? title + " ↓" : title
    }
}

extension MetricsViewModel {
    func menuBarPresentation(display: MenuBarDisplay) -> MenuBarPresentation {
        MenuBarPresentation(
            state: connectionHealth.state, snapshot: snapshot, display: display, showsAvailableUpdate: displayedUpdateStatus == .available)
    }
}
