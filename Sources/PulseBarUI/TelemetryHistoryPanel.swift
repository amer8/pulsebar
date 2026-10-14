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
    public init() {}
}

public enum TelemetryChartScale {
    public static func upperBound(for values: [Double], automatic: Bool) -> Double {
        guard automatic else { return 100 }
        let peak = values.filter(\.isFinite).max() ?? 0
        return min(100, max(5, (peak / 5).rounded(.up) * 5))
    }
}

// Used by both the menu-bar window and native previews.
public struct TelemetryHistoryPanel: View {
    private let state: TelemetryPanelState
    private let now: Date
    private let actions: TelemetryPanelActions
    @Binding private var historySeconds: Int
    @State private var automaticScale: Bool

    public init(
        state: TelemetryPanelState, now: Date, historySeconds: Binding<Int>, actions: TelemetryPanelActions,
        automaticScale: Bool = true
    ) {
        self.state = state
        self.now = now
        _historySeconds = historySeconds
        self.actions = actions
        _automaticScale = State(initialValue: automaticScale)
    }

    public static func preferredSize(for state: TelemetryPanelState) -> CGSize {
        CGSize(width: 400, height: state.systemUpdateAvailable ? 452 : 424)
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                header
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

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(.blue)
                .frame(width: 29, height: 29).background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("PulseBar").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(connectionColor).frame(width: 5, height: 5)
                    Text(state.connectionTitle)
                    if state.lastSampleAt != nil { Text("· " + sampleAge) }
                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if state.canReconnect {
                Button(action: actions.reconnect) { Image(systemName: "arrow.clockwise").padding(6) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Reconnect to dashboard").accessibilityLabel("Reconnect to dashboard")
            }
        }
    }

    private var connectionColor: Color { state.isLive ? .green : (state.needsAttention ? .orange : .secondary) }
    private var sampleAge: String {
        guard let date = state.lastSampleAt else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        return seconds < 2 ? "just updated" : (seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago")
    }
    private var memoryDetail: String {
        guard let used = state.usedMemoryGiB, let total = state.totalMemoryGiB else { return "Waiting for readings" }
        let usage = "\(number(used)) / \(number(total, digits: 0)) GiB used"
        guard let free = state.freeMemoryGiB else { return usage }
        return usage + " · \(number(free)) GiB available"
    }
    private var gpuDetail: String { state.gpuPercent == nil ? "Waiting for readings" : "Graphics utilization" }

    private var historyControls: some View {
        HStack {
            Picker("History range", selection: $historySeconds) {
                Text("1 min").tag(60)
                Text("5 min").tag(300)
                Text("15 min").tag(900)
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 176)
            Spacer()
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
            metricChart(
                title, keyPath: keyPath, upperBound: TelemetryChartScale.upperBound(for: values, automatic: automaticScale), color: color)
        }
    }

    private func metricChart(_ title: String, keyPath: KeyPath<TelemetryChartPoint, Double>, upperBound: Double, color: Color) -> some View
    {
        Chart {
            ForEach(state.points) { point in
                LineMark(
                    x: .value("Time", point.timestamp), y: .value(title, point[keyPath: keyPath]),
                    series: .value("Segment", point.segment)
                )
                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let last = state.points.last {
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
        .frame(height: 86)
        .accessibilityLabel(
            "\(title) utilization over the last \(historySeconds / 60) minutes, scale 0 to \(number(upperBound, digits: 0)) percent")
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
