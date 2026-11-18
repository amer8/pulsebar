import PulseBarUI

struct MenuBarPresentation {
    let state: TelemetryConnectionHealth.State
    let snapshot: MetricsSnapshot
    var display: MenuBarDisplay = .both

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
        switch state {
        case .paused: "\(readings). Reconnection paused. Open PulseBar to reconnect."
        case .expired: "\(readings). Dashboard session expired. Open PulseBar to sign in."
        default: "\(readings). \(state.rawValue)."
        }
    }

    var fallbackTitle: String {
        showsWarning ? "⚠ \(readings)" : readings
    }
}
