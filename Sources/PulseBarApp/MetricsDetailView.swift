import PulseBarUI
import SwiftUI

@MainActor
struct MetricsDetailView: View {
    @ObservedObject var viewModel: MetricsViewModel
    @State private var historySeconds = 300

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TelemetryHistoryPanel(
                state: presentation(at: context.date), now: context.date, historySeconds: $historySeconds, actions: actions)
        }
    }

    private func presentation(at date: Date) -> TelemetryPanelState {
        var state = TelemetryPanelState(connectionTitle: viewModel.connectionHealth.state.rawValue)
        state.isLive = viewModel.connectionHealth.state == .live
        state.needsAttention = [.stale, .reconnecting, .expired].contains(viewModel.connectionHealth.state)
        state.canReconnect = viewModel.isSignedIn
        state.lastSampleAt = viewModel.connectionHealth.lastSampleAt
        state.memoryPercent = viewModel.snapshot.memory.percentUsed
        state.gpuPercent = viewModel.snapshot.gpu.utilizationPercent
        state.usedMemoryGiB = viewModel.snapshot.memory.usedGiB
        state.totalMemoryGiB = viewModel.snapshot.memory.totalGiB
        if state.memoryPercent != nil { state.freeMemoryGiB = viewModel.history.samples.last?.freeGiB }
        state.points = viewModel.history.points(in: HistoryWindow(rawValue: historySeconds) ?? .fiveMinutes, at: date).map {
            TelemetryChartPoint(timestamp: $0.timestamp, memoryPercent: $0.memoryPercent, gpuPercent: $0.gpuPercent, segment: $0.segment)
        }
        state.note = viewModel.snapshot.gpu.note
        state.needsSignIn = !viewModel.isSignedIn && !state.isLive
        state.systemUpdateAvailable = viewModel.isUpdateAvailable
        return state
    }

    private var actions: TelemetryPanelActions {
        var actions = TelemetryPanelActions()
        actions.reconnect = { viewModel.refresh() }
        actions.openDashboard = { PulseBarNavigation.openDashboard() }
        actions.openPreferences = { PulseBarNavigation.openPreferences(viewModel: viewModel) }
        return actions
    }
}

struct MenuBarPreferencesView: View {
    @AppStorage(MenuBarDisplay.preferenceKey) private var display = MenuBarDisplay.both.rawValue
    var body: some View {
        MenuBarPreferencesContent(display: Binding(get: { MenuBarDisplay(rawValue: display) ?? .both }, set: { display = $0.rawValue }))
    }
}
