import AppKit
import Foundation

enum NVIDIASyncAppState: Equatable, Sendable {
    case running
    case notRunning
}

struct NVIDIASyncAppMonitor: Sendable {
    let currentState: @MainActor @Sendable () -> NVIDIASyncAppState

    static let live = NVIDIASyncAppMonitor {
        NSWorkspace.shared.runningApplications.contains { app in
            matches(
                bundleIdentifier: app.bundleIdentifier,
                localizedName: app.localizedName,
                bundleName: app.bundleURL?.deletingPathExtension().lastPathComponent
            )
        } ? .running : .notRunning
    }

    static func matches(bundleIdentifier: String?, localizedName: String?, bundleName: String?) -> Bool {
        [bundleIdentifier, localizedName, bundleName]
            .compactMap(normalizedIdentifier)
            .contains { identifier in
                identifier == "nvidiasync"
                    || identifier == "nvidiasyncapp"
                    || identifier.contains("nvidiasync")
            }
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        value?
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
    }
}

enum DashboardConnectionMessage {
    static func message(for error: Error, syncAppState: NVIDIASyncAppState, endpoint: DashboardEndpoint = .standard) -> String {
        guard error.isLocalDashboardConnectivityError else {
            return error.userFacingMessage
        }

        switch syncAppState {
        case .running:
            return "NVIDIA Sync is running. Open DGX Dashboard, or keep a manual SSH tunnel forwarding \(endpoint.address)."
        case .notRunning:
            return "Expose DGX Dashboard at \(endpoint.address) with NVIDIA Sync or a manual SSH tunnel: \(endpoint.tunnelCommand)"
        }
    }
}

enum DashboardError: LocalizedError {
    case invalidResponse
    case invalidSessionToken
    case unauthorized
    case loginFailed
    case missingTelemetry
    case telemetryLineTooLong
    case telemetryEventTooLarge
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidSessionToken:
            return "The dashboard session token is invalid. Sign in again."
        case .invalidResponse:
            return "The dashboard returned an unexpected response."
        case .unauthorized:
            return "The dashboard rejected the current session."
        case .loginFailed:
            return "Login failed. Check your dashboard credentials."
        case .missingTelemetry:
            return "The telemetry stream did not include GPU data."
        case .telemetryLineTooLong:
            return "A telemetry stream line exceeded the size limit."
        case .telemetryEventTooLarge:
            return "A telemetry stream event exceeded the size limit."
        case .server(let message):
            return message
        }
    }
}

enum MetricNumberFormat {
    static func usedMemoryGiBString(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        decimalString(value, fractionDigits: 2, locale: locale)
    }

    static func wholeNumberString(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        decimalString(value, fractionDigits: 0, locale: locale)
    }

    private static func decimalString(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.usesGroupingSeparator = false

        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

extension Error {
    var userFacingMessage: String {
        if let localizedError = self as? LocalizedError,
            let description = localizedError.errorDescription
        {
            return description
        }

        return localizedDescription
    }

    fileprivate var isLocalDashboardConnectivityError: Bool {
        guard let urlError = self as? URLError else {
            return false
        }

        switch urlError.code {
        case .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .timedOut:
            return true
        default:
            return false
        }
    }
}

// RFC 6750 bearer credentials: a nonempty base64-like value with optional trailing padding.
enum DashboardSessionToken {
    static func validate(_ token: String) throws {
        let bytes = Array(token.utf8)
        var padding = false
        guard !bytes.isEmpty else { throw DashboardError.invalidSessionToken }
        var hasValue = false
        for byte in bytes {
            if byte == 61 {
                padding = true
            } else if !padding
                && ((65...90).contains(byte) || (97...122).contains(byte)
                    || (48...57).contains(byte) || [45, 46, 95, 126, 43, 47].contains(byte))
            {
                hasValue = true
            } else {
                throw DashboardError.invalidSessionToken
            }
        }
        guard hasValue else { throw DashboardError.invalidSessionToken }
    }
}
