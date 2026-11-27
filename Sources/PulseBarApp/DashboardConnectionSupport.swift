import Foundation

enum DashboardConnectionMessage {
    static let missingConnection =
        "In Preferences → Devices, choose + Add new to select an SSH alias, or select a device you already added."

    static func message(for error: Error, endpoint: DashboardEndpoint) -> String {
        guard error.isLocalDashboardConnectivityError else { return error.userFacingMessage }
        guard let host = endpoint.sshHost else { return missingConnection }
        return "Check SSH access to \(host) and the dashboard at \(endpoint.address) on that host."
    }
}

enum DashboardError: LocalizedError {
    case unknownSSHHostKey
    case invalidResponse
    case invalidSessionToken
    case unauthorized
    case loginFailed
    case missingTelemetry
    case responseTooLarge
    case telemetryLineTooLong
    case telemetryEventTooLarge
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unknownSSHHostKey:
            return "SSH could not verify the host key. Confirm the fingerprint independently before connecting."
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
        case .responseTooLarge:
            return "The dashboard JSON response exceeded the size limit."
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
