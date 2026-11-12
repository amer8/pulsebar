import Charts
import SwiftUI

public struct TelemetryChartPoint: Identifiable, Sendable {
    public let timestamp: Date
    public let memoryPercent: Double
    public let gpuPercent: Double
    public let segment: Int
    public var id: Date { timestamp }

    public init(timestamp: Date, memoryPercent: Double, gpuPercent: Double, segment: Int = 0) {
        self.timestamp = timestamp
        self.memoryPercent = memoryPercent
        self.gpuPercent = gpuPercent
        self.segment = segment
    }
}

public struct TelemetryPanelState {
    public var connectionTitle: String
    public var isLive = false
    public var needsAttention = false
    public var canReconnect = false
    public var lastSampleAt: Date?
    public var memoryPercent: Double?
    public var gpuPercent: Double?
    public var usedMemoryGiB: Double?
    public var totalMemoryGiB: Double?
    public var freeMemoryGiB: Double?
    public var points: [TelemetryChartPoint] = []
    public var note: String?
    public var needsSignIn = false
    public var systemUpdateAvailable = false

    public init(connectionTitle: String) { self.connectionTitle = connectionTitle }
}

public struct TelemetryPanelActions {
    public var reconnect: () -> Void = {}
    public var openDashboard: () -> Void = {}
    public var openPreferences: () -> Void = {}
    public var quit: () -> Void = {}
    public init() {}
}

public enum TelemetryChartScale {
    public static func upperBound(for values: [Double], automatic: Bool) -> Double {
        guard automatic else { return 100 }
        let peak = values.filter(\.isFinite).max() ?? 0
        return min(100, max(5, (peak / 5).rounded(.up) * 5))
    }
}

public enum TelemetryChartSelection {
    public static func nearest(
        to date: Date, in points: [TelemetryChartPoint], within maximumDistance: TimeInterval
    ) -> TelemetryChartPoint? {
        guard maximumDistance >= 0,
            let point = points.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }),
            abs(point.timestamp.timeIntervalSince(date)) <= maximumDistance
        else { return nil }
        return point
    }
}

// Used by both the menu-bar window and native previews.
public struct TelemetryHistoryPanel: View {
    private let state: TelemetryPanelState
    private let now: Date
    private let actions: TelemetryPanelActions
    @Binding private var historySeconds: Int
    @Binding private var automaticScale: Bool
    @State private var isShowingAbout = false

    public init(
        state: TelemetryPanelState, now: Date, historySeconds: Binding<Int>, actions: TelemetryPanelActions,
        automaticScale: Binding<Bool> = .constant(true)
    ) {
        self.state = state
        self.now = now
        _historySeconds = historySeconds
        self.actions = actions
        _automaticScale = automaticScale
    }

    public static func preferredSize(for state: TelemetryPanelState) -> CGSize {
        CGSize(width: 400, height: state.systemUpdateAvailable ? 416 : 388)
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                historyControls
                if state.points.isEmpty {
                    readingHeader("RAM", symbol: "memorychip", value: state.memoryPercent, peak: nil, detail: memoryDetail)
                    readingHeader("GPU", symbol: "cpu", value: state.gpuPercent, peak: nil, detail: gpuDetail)
                    emptyHistory
                } else {
                    metricSeries(
                        "RAM", symbol: "memorychip", value: state.memoryPercent, values: state.points.map(\.memoryPercent),
                        detail: memoryDetail, keyPath: \.memoryPercent, color: .blue)
                    metricSeries(
                        "GPU", symbol: "cpu", value: state.gpuPercent, values: state.points.map(\.gpuPercent),
                        detail: gpuDetail, keyPath: \.gpuPercent, color: .teal)
                    timeAxis
                }
                if let note = state.note, !state.needsSignIn {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if state.systemUpdateAvailable {
                    Button(action: actions.openDashboard) {
                        HStack {
                            Label("DGX system update available", systemImage: "arrow.down.circle")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }.font(.caption).foregroundStyle(.orange)
                    }.buttonStyle(.plain).help("Open the dashboard to review the system update")
                }
            }
            .padding(16).frame(width: 400)
        }
        // Keep the viewport finite when MenuBarExtra probes its compressed opening size.
        .frame(width: Self.preferredSize(for: state).width, height: Self.preferredSize(for: state).height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var actionsMenu: some View {
        Menu {
            Button(action: actions.openDashboard) { Label("Open Dashboard", systemImage: "safari") }
            if state.canReconnect {
                Button(action: actions.reconnect) { Label("Reconnect", systemImage: "arrow.clockwise") }
            }
            Button(action: actions.openPreferences) { Label("Preferences…", systemImage: "gearshape") }
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button {
                isShowingAbout = true
            } label: {
                Label("About PulseBar", systemImage: "info.circle")
            }
            Divider()
            Button(action: actions.quit) { Label("Quit PulseBar", systemImage: "power") }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 16)).padding(6)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(.secondary)
        .help("Dashboard, preferences, about, and quit").accessibilityLabel("PulseBar actions")
        .popover(isPresented: $isShowingAbout, arrowEdge: .top) {
            PulseBarAboutContent().onExitCommand { isShowingAbout = false }
        }
    }

    private var connectionColor: Color { state.isLive ? .green : (state.needsAttention ? .orange : .secondary) }
    private var sampleAge: String {
        guard let date = state.lastSampleAt else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        return seconds < 2 ? "just updated" : (seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago")
    }
    private var connectionDescription: String {
        state.connectionTitle + (state.lastSampleAt == nil ? "" : " · " + sampleAge)
    }
    private var memoryDetail: String {
        guard let used = state.usedMemoryGiB, let total = state.totalMemoryGiB else { return "Waiting for readings" }
        let usage = "\(number(used)) / \(number(total, digits: 0)) GiB used"
        guard let free = state.freeMemoryGiB else { return usage }
        return usage + " · \(number(free)) GiB available"
    }
    private var gpuDetail: String { state.gpuPercent == nil ? "Waiting for readings" : "Graphics utilization" }

    private var historyControls: some View {
        HStack(spacing: 8) {
            Text("PulseBar")
                .font(.system(size: 12, weight: .semibold))
            Circle().fill(connectionColor).frame(width: 6, height: 6)
                .help(connectionDescription)
                .accessibilityLabel("Connection status")
                .accessibilityValue(connectionDescription)
            Spacer(minLength: 8)
            Button {
                switch historySeconds {
                case 60: historySeconds = 300
                case 300: historySeconds = 900
                default: historySeconds = 60
                }
            } label: {
                Text("Range: \(historySeconds / 60) min")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Click to switch between 1, 5, and 15 minutes.")
            .accessibilityLabel("History range")
            .accessibilityValue("\(historySeconds / 60) minutes")
            Button {
                automaticScale.toggle()
            } label: {
                Text(automaticScale ? "Scale: Auto" : "Scale: 0–100%")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help(
                automaticScale ? "Click to show both charts on a 0–100% scale." : "Click to fit a separate, labelled scale to each chart."
            )
            .accessibilityLabel("Chart scale")
            .accessibilityValue(automaticScale ? "Automatic" : "0 to 100 percent")
            actionsMenu
        }
    }

    private func readingHeader(_ title: String, symbol: String, value: Double?, peak: Double?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(title, systemImage: symbol).font(.subheadline.weight(.medium))
                Text(percent(value)).font(.system(size: 21, weight: .semibold)).monospacedDigit()
                Spacer()
                if let peak { Text("Peak \(percent(peak))").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metricSeries(
        _ title: String, symbol: String, value: Double?, values: [Double], detail: String,
        keyPath: KeyPath<TelemetryChartPoint, Double>, color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            readingHeader(title, symbol: symbol, value: value, peak: values.max(), detail: detail)
            TelemetryMetricChart(
                title, keyPath: keyPath, upperBound: TelemetryChartScale.upperBound(for: values, automatic: automaticScale), color: color,
                points: state.points, now: now, historySeconds: historySeconds)
        }
    }

    private var timeAxis: some View {
        HStack {
            Text("\(historySeconds / 60) min ago")
            Spacer()
            Text("Now")
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 44).padding(.top, -12)
    }

    private var emptyHistory: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(.tertiary)
            Text(state.needsSignIn ? "Connect your dashboard" : "Waiting for telemetry").font(.subheadline.weight(.medium))
            if state.needsSignIn {
                Text("Sign in to start collecting live telemetry.").font(.caption).foregroundStyle(.secondary)
                Button("Open Preferences…", action: actions.openPreferences).buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Text("Your history will appear as samples arrive.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).frame(height: 154)
    }

    private func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "—" }
    private func number(_ value: Double, digits: Int = 2) -> String { value.formatted(.number.precision(.fractionLength(0...digits))) }
}

private struct TelemetryMetricChart: View {
    let title: String
    let keyPath: KeyPath<TelemetryChartPoint, Double>
    let upperBound: Double
    let color: Color
    let points: [TelemetryChartPoint]
    let now: Date
    let historySeconds: Int
    @State private var hoveredTimestamp: Date?

    init(
        _ title: String, keyPath: KeyPath<TelemetryChartPoint, Double>, upperBound: Double, color: Color,
        points: [TelemetryChartPoint], now: Date, historySeconds: Int
    ) {
        self.title = title
        self.keyPath = keyPath
        self.upperBound = upperBound
        self.color = color
        self.points = points
        self.now = now
        self.historySeconds = historySeconds
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.timestamp), y: .value(title, point[keyPath: keyPath]),
                    series: .value("Segment", point.segment)
                )
                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let last = points.last {
                PointMark(x: .value("Time", last.timestamp), y: .value(title, last[keyPath: keyPath]))
                    .foregroundStyle(color).symbolSize(20)
            }
        }
        .chartYScale(domain: 0...upperBound, range: .plotDimension(startPadding: 4, endPadding: 4))
        .chartXScale(domain: now.addingTimeInterval(-Double(historySeconds))...now)
        .chartLegend(.hidden).chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, upperBound / 2, upperBound]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text("\(number(percent, digits: 1))%").font(.system(size: 10))
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = geometry[proxy.plotAreaFrame]
                ZStack(alignment: .topLeading) {
                    if let timestamp = hoveredTimestamp,
                        let point = points.first(where: { $0.timestamp == timestamp }),
                        let x = proxy.position(forX: point.timestamp),
                        let y = proxy.position(forY: point[keyPath: keyPath])
                    {
                        Rectangle().fill(Color.secondary.opacity(0.6))
                            .frame(width: 1, height: plot.height)
                            .position(x: plot.minX + x, y: plot.midY)
                        Circle().fill(color).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                            .position(x: plot.minX + x, y: plot.minY + y)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.timestamp, format: .dateTime.hour().minute().second())
                            Text("\(title) \(number(point[keyPath: keyPath], digits: 1))%")
                        }
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .padding(5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                        .fixedSize()
                        .position(x: min(max(plot.minX + x, plot.minX + 42), plot.maxX - 42), y: plot.minY + 18)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard plot.contains(location), plot.width > 0,
                            let date: Date = proxy.value(atX: location.x - plot.minX)
                        else {
                            hoveredTimestamp = nil
                            return
                        }
                        let tolerance = Double(historySeconds) * 24 / plot.width
                        hoveredTimestamp = TelemetryChartSelection.nearest(to: date, in: points, within: tolerance)?.timestamp
                    case .ended:
                        hoveredTimestamp = nil
                    }
                }
            }
        }
        .frame(height: 86)
        .accessibilityLabel(
            "\(title) utilization over the last \(historySeconds / 60) minutes, scale 0 to \(number(upperBound, digits: 0)) percent"
        )
        .onChange(of: historySeconds) { _ in hoveredTimestamp = nil }
    }

    private func number(_ value: Double, digits: Int = 2) -> String { value.formatted(.number.precision(.fractionLength(0...digits))) }
}
