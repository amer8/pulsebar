import Foundation

enum HistoryWindow: Int, CaseIterable, Identifiable {
    case minute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .minute: "1 min"
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        }
    }
}

struct TelemetryHistoryPoint: Identifiable, Sendable {
    let timestamp: Date
    let memoryPercent: Double
    let gpuPercent: Double
    let freeGiB: Double
    let segment: Int
    var id: Date { timestamp }
}

struct TelemetryHistory: Sendable {
    private(set) var samples: [TelemetryHistoryPoint] = []
    private var segment = 0
    let maximumSamples: Int
    let maximumAge: TimeInterval

    init(maximumSamples: Int = 3_600, maximumAge: TimeInterval = 900) {
        self.maximumSamples = max(1, maximumSamples)
        self.maximumAge = max(1, maximumAge)
    }
    mutating func markGap() { segment += 1 }
    static func accepts(_ sample: TelemetrySample) -> Bool {
        sample.gpuUtilizationPercent.isFinite && (0...100).contains(sample.gpuUtilizationPercent)
            && sample.memoryTotalMB.isFinite && sample.memoryTotalMB > 0
            && sample.memoryAvailableMB.isFinite && (0...sample.memoryTotalMB).contains(sample.memoryAvailableMB)
    }
    mutating func append(_ sample: TelemetrySample, at date: Date) {
        guard Self.accepts(sample) else { return }
        if let last = samples.last, date < last.timestamp {
            samples.removeAll()
            markGap()
        }
        if samples.last?.timestamp == date { samples.removeLast() }
        samples.append(
            TelemetryHistoryPoint(
                timestamp: date, memoryPercent: (1 - sample.memoryAvailableMB / sample.memoryTotalMB) * 100,
                gpuPercent: sample.gpuUtilizationPercent, freeGiB: sample.memoryAvailableMB / 1024, segment: segment
            ))
        samples.removeAll { date.timeIntervalSince($0.timestamp) > maximumAge }
        if samples.count > maximumSamples { samples.removeFirst(samples.count - maximumSamples) }
    }
    func points(in window: HistoryWindow, at now: Date) -> [TelemetryHistoryPoint] {
        samples.filter { $0.timestamp <= now && now.timeIntervalSince($0.timestamp) <= Double(window.rawValue) }
    }
}
