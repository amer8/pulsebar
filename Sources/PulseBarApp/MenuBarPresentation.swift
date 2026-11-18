import PulseBarUI

struct MenuBarPresentation {
    let state: TelemetryConnectionHealth.State
    let snapshot: MetricsSnapshot
    var display: MenuBarDisplay = .both
    var updateStatus: SystemUpdateStatus = .hidden

    var showsWarning: Bool { state == .paused || state == .expired }

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
        case .paused: connection = "\(readings). Reconnection paused. Open PulseBar to reconnect."
        case .expired: connection = "\(readings). Dashboard session expired. Open PulseBar to sign in."
        default: connection = "\(readings). \(state.rawValue)."
        }
        guard let indicator = MenuBarUpdateIndicator(status: updateStatus) else { return connection }
        return connection + " " + indicator.accessibilityDescription + "."
    }

    var fallbackTitle: String {
        let title = showsWarning ? "⚠ \(readings)" : readings
        guard let indicator = MenuBarUpdateIndicator(status: updateStatus) else { return title }
        return title + (indicator.isStale ? " ↓?" : " ↓")
    }
}
