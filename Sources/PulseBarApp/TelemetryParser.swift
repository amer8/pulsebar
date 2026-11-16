import Foundation

private struct TelemetryPayload: Decodable {
    let telemetryForGPUs: [TelemetrySample]

    private enum CodingKeys: String, CodingKey {
        case telemetryForGPUs = "TelemetryForGPUs"
    }
}

struct TelemetrySample: Decodable, Sendable {
    let gpuUtilizationPercent: Double
    let memoryTotalMB: Double
    let memoryAvailableMB: Double

    private enum CodingKeys: String, CodingKey {
        case gpuUtilizationPercent = "percentage_utilization"
        case memoryTotalMB = "memory_total_in_mb"
        case memoryAvailableMB = "memory_available_in_mb"
        case memoryTotalKiB = "memory_total_in_kib"
        case memoryAvailableKiB = "memory_available_in_kib"
    }
}

extension TelemetrySample {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gpuUtilizationPercent = try container.decode(Double.self, forKey: .gpuUtilizationPercent)
        // Current dashboards report KiB; normalize to the units used by existing views.
        // Require a complete pair so mixed payloads cannot silently combine different units.
        if container.contains(.memoryTotalKiB) || container.contains(.memoryAvailableKiB) {
            memoryTotalMB = try container.decode(Double.self, forKey: .memoryTotalKiB) / 1024
            memoryAvailableMB = try container.decode(Double.self, forKey: .memoryAvailableKiB) / 1024
        } else {
            memoryTotalMB = try container.decode(Double.self, forKey: .memoryTotalMB)
            memoryAvailableMB = try container.decode(Double.self, forKey: .memoryAvailableMB)
        }
    }
}

enum TelemetryParser {
    static func firstSample(from data: Data) throws -> TelemetrySample {
        let payload: TelemetryPayload
        do {
            payload = try JSONDecoder().decode(TelemetryPayload.self, from: data)
        } catch DecodingError.keyNotFound(let key, _) {
            throw DashboardError.server("Dashboard telemetry is missing '\(key.stringValue)'.")
        } catch DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context) {
            let field = context.codingPath.last?.stringValue ?? "payload"
            throw DashboardError.server("Dashboard telemetry has an invalid value for '\(field)'.")
        } catch DecodingError.dataCorrupted {
            throw DashboardError.server("Dashboard telemetry contains invalid JSON or numeric data.")
        }
        guard let sample = payload.telemetryForGPUs.first else {
            throw DashboardError.missingTelemetry
        }

        guard sample.gpuUtilizationPercent.isFinite, (0...100).contains(sample.gpuUtilizationPercent),
            sample.memoryTotalMB.isFinite, sample.memoryTotalMB > 0,
            sample.memoryAvailableMB.isFinite, (0...sample.memoryTotalMB).contains(sample.memoryAvailableMB)
        else { throw DashboardError.server("The dashboard returned invalid telemetry.") }
        return sample
    }
}
