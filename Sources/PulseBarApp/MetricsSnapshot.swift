import Foundation

struct MetricsSnapshot {
    let memory: MemorySnapshot
    let gpu: GPUSnapshot
    let timestamp: Date

    var menuBarTitle: String {
        "RAM \(memory.percentText) GPU \(gpu.menuBarText)"
    }

    static func signedOut(note: String? = nil) -> MetricsSnapshot {
        MetricsSnapshot(
            memory: MemorySnapshot(statusText: "Unavailable"),
            gpu: GPUSnapshot(
                deviceName: "GPU",
                utilizationPercent: nil,
                statusText: "Unavailable",
                note: note
            ),
            timestamp: .now
        )
    }

    static func connecting(username: String) -> MetricsSnapshot {
        let prefix = username.isEmpty ? "Connecting to local dashboard…" : "Connecting to local dashboard as \(username)…"

        return MetricsSnapshot(
            memory: MemorySnapshot(statusText: "Connecting…"),
            gpu: GPUSnapshot(
                deviceName: "GPU",
                utilizationPercent: nil,
                statusText: "Connecting…",
                note: prefix
            ),
            timestamp: .now
        )
    }

    static func live(_ sample: TelemetrySample) -> MetricsSnapshot {
        let usedGiB = max((sample.memoryTotalMB - sample.memoryAvailableMB) / 1024, 0)
        let actualTotalGiB = max(sample.memoryTotalMB / 1024, 0)
        let totalGiB = actualTotalGiB.rounded(.up)
        let percentUsed = actualTotalGiB > 0 ? (usedGiB / actualTotalGiB) * 100 : 0

        return MetricsSnapshot(
            memory: MemorySnapshot(
                usedGiB: usedGiB,
                totalGiB: totalGiB,
                percentUsed: percentUsed,
                statusText: nil
            ),
            gpu: GPUSnapshot(
                deviceName: "GPU",
                utilizationPercent: sample.gpuUtilizationPercent,
                statusText: nil,
                note: nil
            ),
            timestamp: .now
        )
    }

    func replacingTelemetryUnavailable(note: String?, statusText: String, timestamp: Date) -> MetricsSnapshot {
        MetricsSnapshot(
            memory: MemorySnapshot(statusText: statusText),
            gpu: GPUSnapshot(
                deviceName: gpu.deviceName,
                utilizationPercent: nil,
                statusText: statusText,
                note: note
            ),
            timestamp: timestamp
        )
    }
}

struct MemorySnapshot {
    let usedGiB: Double?
    let totalGiB: Double?
    let percentUsed: Double?
    let statusText: String?

    init(
        usedGiB: Double? = nil,
        totalGiB: Double? = nil,
        percentUsed: Double? = nil,
        statusText: String? = nil
    ) {
        self.usedGiB = usedGiB
        self.totalGiB = totalGiB
        self.percentUsed = percentUsed
        self.statusText = statusText
    }

    var percentText: String {
        guard let percentUsed else {
            return "--"
        }

        return "\(Int(percentUsed.rounded()))%"
    }

}

struct GPUSnapshot {
    let deviceName: String?
    let utilizationPercent: Double?
    let statusText: String?
    let note: String?

    var menuBarText: String {
        guard let utilizationPercent else {
            return "--"
        }

        return "\(Int(utilizationPercent.rounded()))%"
    }

}
