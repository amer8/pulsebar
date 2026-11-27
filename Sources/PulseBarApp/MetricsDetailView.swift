import PulseBarUI
import SwiftUI

@MainActor
struct MetricsDetailView: View {
    @ObservedObject var sessions: DeviceSessions
    @AppStorage("PulseBar.HistorySeconds") private var historySeconds = 300
    @AppStorage("PulseBar.AutomaticChartScale") private var automaticScale = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TelemetryHistoryPanel(
                state: sessions.panelState(at: context.date, historyWindow: historyWindow), now: context.date,
                historySeconds: Binding(
                    get: { historyWindow.rawValue },
                    set: { historySeconds = $0 }),
                actions: actions, automaticScale: $automaticScale
            )
            .id(sessions.displayed.endpoint)
        }
    }

    private var historyWindow: HistoryWindow { HistoryWindow(rawValue: historySeconds) ?? .fiveMinutes }

    private var actions: TelemetryPanelActions {
        var actions = TelemetryPanelActions()
        actions.selectDevice = sessions.display
        actions.addDevice = {
            dismiss()
            PulseBarNavigation.openPreferences(sessions: sessions, addingDevice: true)
        }
        let model = sessions.displayed
        actions.openSync = {
            dismiss()
            Task { await PulseBarNavigation.openNVIDIASync() }
        }
        let openPreferences = {
            dismiss()
            PulseBarNavigation.openPreferences(sessions: sessions)
        }
        actions.openPreferences = openPreferences
        actions.openAccountPreferences = {
            if let alias = model.endpoint.sshHost { sessions.manage(alias) }
            openPreferences()
        }
        actions.reconnect = { model.refresh() }
        actions.quit = { model.quit() }
        return actions
    }
}

extension DeviceSessions {
    func panelState(at date: Date, historyWindow: HistoryWindow) -> TelemetryPanelState {
        var state = displayed.panelState(at: date, historyWindow: historyWindow)
        state.selectedDevice = displayed.endpoint.sshHost
        state.devices = devices
        return state
    }
}

extension MetricsViewModel {
    func panelState(at date: Date, historyWindow: HistoryWindow) -> TelemetryPanelState {
        if connectionHealth.state == .expired { return .expiredSession() }
        var state = TelemetryPanelState(connectionTitle: connectionHealth.state.rawValue, deviceName: isSignedIn ? endpoint.sshHost : nil)
        state.isAuthenticating = isAuthenticating
        state.isLive = connectionHealth.state == .live
        state.needsAttention = [.stale, .reconnecting, .paused].contains(connectionHealth.state)
        state.canReconnect = isSignedIn
        if connectionHealth.state == .paused { state.recoveryAction = .reconnect }
        state.lastSampleAt = connectionHealth.lastSampleAt
        state.memoryPercent = snapshot.memory.percentUsed
        state.gpuPercent = snapshot.gpu.utilizationPercent
        state.usedMemoryGiB = snapshot.memory.usedGiB
        state.totalMemoryGiB = snapshot.memory.totalGiB
        if state.memoryPercent != nil { state.freeMemoryGiB = history.samples.last?.freeGiB }
        state.points = history.points(in: historyWindow, at: date).map {
            TelemetryChartPoint(timestamp: $0.timestamp, memoryPercent: $0.memoryPercent, gpuPercent: $0.gpuPercent, segment: $0.segment)
        }
        state.note = telemetryPanelNote
        state.needsSignIn = !isSignedIn && !state.isLive && !isAuthenticating
        state.needsSessionRestore = sessionLoadIssue != nil
        state.hasConfiguredDevice = endpoint.sshHost != nil
        state.systemUpdateStatus = displayedUpdateStatus
        return state
    }

}

struct MenuBarPreferencesView: View {
    @AppStorage(MenuBarDisplay.preferenceKey) private var display = MenuBarDisplay.both.rawValue
    var body: some View {
        MenuBarPreferencesContent(display: Binding(get: { MenuBarDisplay(rawValue: display) ?? .both }, set: { display = $0.rawValue }))
    }
}
