import Foundation

enum TelemetryStreamStatus: Sendable {
    case connected
    case unrecognizedEvent(String)
}

protocol DashboardServing: Sendable {
    func login(username: String, password: String) async throws -> String
    func checkConnection() async throws -> Bool
    func updateAvailability(token: String) async throws -> UpdateAvailability
    func consumeTelemetryStream(
        token: String,
        onLog: @escaping @Sendable (String) -> Void,
        onStatus: @escaping @Sendable (TelemetryStreamStatus) async -> Void,
        onSample: @escaping @Sendable (TelemetrySample) async -> Void
    ) async throws
}

private struct LoginResponse: Decodable {
    let token: String
}

private struct DashboardErrorResponse: Decodable {
    let error: String
}

struct UpdateAvailability: Decodable, Sendable {
    let available: Bool
}

struct DashboardClient: DashboardServing {
    static let maximumLineBytes = 64 * 1024
    static let maximumEventBytes = 256 * 1024
    static let maximumJSONBytes = 64 * 1024

    private let transport: DashboardSSHTransport
    private var baseURL: URL { transport.origin }

    init(endpoint: DashboardEndpoint) { transport = DashboardSSHTransport(endpoint: endpoint) }

    init(transport: DashboardSSHTransport) { self.transport = transport }

    func checkConnection() async throws -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 5
        for method in ["HEAD", "GET"] {
            request.httpMethod = method
            let status = try await transport.withResponse(to: request) { status, _ in status }
            if method == "HEAD", [405, 501].contains(status) { continue }
            return (200..<400).contains(status)
        }
        return false
    }

    func login(username: String, password: String) async throws -> String {
        var request = URLRequest(url: endpoint("/api/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
        ])

        let (data, status) = try await jsonResponse(for: request)

        guard status == 200 else {
            if status == 401 {
                throw DashboardError.loginFailed
            }

            if let errorResponse = try? JSONDecoder().decode(DashboardErrorResponse.self, from: data) {
                throw DashboardError.server(errorResponse.error)
            }

            throw DashboardError.loginFailed
        }

        let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)
        try DashboardSessionToken.validate(loginResponse.token)
        return loginResponse.token
    }

    func updateAvailability(token: String) async throws -> UpdateAvailability {
        try DashboardSessionToken.validate(token)
        var request = URLRequest(url: endpoint("/api/v1/updates/available"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, status) = try await jsonResponse(for: request)

        if status == 401 {
            throw DashboardError.unauthorized
        }

        guard status == 200 else {
            if let errorResponse = try? JSONDecoder().decode(DashboardErrorResponse.self, from: data) {
                throw DashboardError.server(errorResponse.error)
            }

            throw DashboardError.server("Unable to check system update availability.")
        }

        return try JSONDecoder().decode(UpdateAvailability.self, from: data)
    }

    func consumeTelemetryStream(
        token: String,
        onLog: @escaping @Sendable (String) -> Void = { _ in },
        onStatus: @escaping @Sendable (TelemetryStreamStatus) async -> Void = { _ in },
        onSample: @escaping @Sendable (TelemetrySample) async -> Void
    ) async throws {
        try DashboardSessionToken.validate(token)
        var request = URLRequest(url: endpoint("/api/v1/gpu_telemetry/stream"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        onLog("Requesting /api/v1/gpu_telemetry/stream.")

        try await transport.withResponse(to: request) { status, reader in
            try await readTelemetry(status: status, reader: reader, onLog: onLog, onStatus: onStatus, onSample: onSample)
        }
    }

    private func readTelemetry(
        status: Int, reader: DashboardResponseReader, onLog: @escaping @Sendable (String) -> Void,
        onStatus: @escaping @Sendable (TelemetryStreamStatus) async -> Void,
        onSample: @escaping @Sendable (TelemetrySample) async -> Void
    ) async throws {
        onLog("Telemetry stream responded with HTTP \(status).")

        if status == 401 {
            throw DashboardError.unauthorized
        }

        guard status == 200 else {
            throw DashboardError.server("Unable to open the telemetry stream.")
        }

        await onStatus(.connected)
        onLog("Telemetry stream is open. Waiting for SSE events.")

        var eventName = ""
        var dataLines: [String] = []
        var lineBuffer: [UInt8] = []
        var previousWasCarriageReturn = false
        var eventByteCount = 0
        var consecutiveUnknownEvents = 0

        func handleLine() async throws {
            let line = String(decoding: lineBuffer, as: UTF8.self)
            lineBuffer.removeAll(keepingCapacity: true)

            if line.isEmpty {
                try await handleEvent(
                    name: eventName, dataLines: dataLines, consecutiveUnknownEvents: &consecutiveUnknownEvents,
                    onLog: onLog, onStatus: onStatus, onSample: onSample)
                eventName = ""
                dataLines.removeAll(keepingCapacity: true)
                eventByteCount = 0
                return
            }
            if line.hasPrefix(":") { return }

            let (field, value) = parseSSEField(line)
            switch field {
            case "event": eventName = value
            case "data": dataLines.append(value)
            default: break
            }
        }

        while let byte = try await reader.next() {
            if Task.isCancelled { throw CancellationError() }
            if byte == 0x0A && previousWasCarriageReturn {
                previousWasCarriageReturn = false
                continue
            }
            previousWasCarriageReturn = byte == 0x0D

            // Count each line ending once, including the blank line that dispatches the event.
            guard eventByteCount < Self.maximumEventBytes else { throw DashboardError.telemetryEventTooLarge }
            eventByteCount += 1
            if previousWasCarriageReturn || byte == 0x0A {
                try await handleLine()
            } else {
                guard lineBuffer.count < Self.maximumLineBytes else { throw DashboardError.telemetryLineTooLong }
                lineBuffer.append(byte)
            }
        }
    }

    private func handleEvent(
        name: String,
        dataLines: [String],
        consecutiveUnknownEvents: inout Int,
        onLog: @escaping @Sendable (String) -> Void,
        onStatus: @escaping @Sendable (TelemetryStreamStatus) async -> Void,
        onSample: @escaping @Sendable (TelemetrySample) async -> Void
    ) async throws {
        guard !dataLines.isEmpty else {
            return
        }

        switch name {
        case "gpu_telemetry":
            consecutiveUnknownEvents = 0
            let data = Data(dataLines.joined(separator: "\n").utf8)
            do {
                await onSample(try TelemetryParser.firstSample(from: data))
            } catch let error as DashboardError {
                onLog("Skipped telemetry event: \(error.localizedDescription)")
            }

        case "error":
            onLog("Received error event from telemetry stream.")
            let data = Data(dataLines.joined(separator: "\n").utf8)
            if let errorResponse = try? JSONDecoder().decode(DashboardErrorResponse.self, from: data) {
                throw DashboardError.server(errorResponse.error)
            }
            throw DashboardError.server("The telemetry stream returned an error.")

        default:
            let displayName = String(name.unicodeScalars.prefix(64)).components(separatedBy: .controlCharacters).joined()
            let eventName = displayName.isEmpty ? "message" : displayName
            onLog("Ignored SSE event '\(eventName)'.")
            let warningThreshold = 3
            guard consecutiveUnknownEvents < warningThreshold else { return }
            consecutiveUnknownEvents += 1
            if consecutiveUnknownEvents == warningThreshold {
                await onStatus(.unrecognizedEvent(eventName))
            }
        }
    }

    private func jsonResponse(for request: URLRequest) async throws -> (Data, Int) {
        try await transport.withResponse(to: request) { status, reader in
            if status == 401 { return (Data(), status) }
            var body = Data()
            while let byte = try await reader.next() {
                guard body.count < Self.maximumJSONBytes else { throw DashboardError.responseTooLarge }
                body.append(byte)
            }
            return (body, status)
        }
    }

    private func endpoint(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private func parseSSEField(_ line: String) -> (field: String, value: String) {
        guard let separator = line.firstIndex(of: ":") else {
            return (line, "")
        }

        let field = String(line[..<separator])
        var value = String(line[line.index(after: separator)...])

        if value.first == " " {
            value.removeFirst()
        }

        return (field, value)
    }
}
