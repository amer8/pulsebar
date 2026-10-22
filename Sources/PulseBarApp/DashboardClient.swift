import Foundation

protocol DashboardServing: Sendable {
    func login(username: String, password: String) async throws -> String
    func checkConnection() async throws -> Bool
    func updateAvailability(token: String) async throws -> UpdateAvailability
    func consumeTelemetryStream(
        token: String,
        onLog: @escaping @Sendable (String) -> Void,
        onConnected: @escaping @Sendable () async -> Void,
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
    private let session: URLSession
    private let baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:11000")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func checkConnection() async throws -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 5
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<400).contains(http.statusCode)
    }

    func login(username: String, password: String) async throws -> String {
        var request = URLRequest(url: endpoint("/api/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DashboardError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw DashboardError.loginFailed
            }

            if let errorResponse = try? JSONDecoder().decode(DashboardErrorResponse.self, from: data) {
                throw DashboardError.server(errorResponse.error)
            }

            throw DashboardError.loginFailed
        }

        let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)
        return loginResponse.token
    }

    func updateAvailability(token: String) async throws -> UpdateAvailability {
        var request = URLRequest(url: endpoint("/api/v1/updates/available"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DashboardError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw DashboardError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
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
        onConnected: @escaping @Sendable () async -> Void = {},
        onSample: @escaping @Sendable (TelemetrySample) async -> Void
    ) async throws {
        var request = URLRequest(url: endpoint("/api/v1/gpu_telemetry/stream"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        onLog("Requesting /api/v1/gpu_telemetry/stream.")

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DashboardError.invalidResponse
        }

        onLog("Telemetry stream responded with HTTP \(httpResponse.statusCode).")

        if httpResponse.statusCode == 401 {
            throw DashboardError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            throw DashboardError.server("Unable to open the telemetry stream.")
        }

        await onConnected()
        onLog("Telemetry stream is open. Waiting for SSE events.")

        var eventName = ""
        var dataLines: [String] = []
        var lineBuffer: [UInt8] = []
        var previousWasCarriageReturn = false

        for try await byte in bytes {
            if Task.isCancelled {
                throw CancellationError()
            }

            if byte == 0x0D {
                let line = decodeSSELine(from: lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)
                previousWasCarriageReturn = true

                if line.isEmpty {
                    try await handleEvent(
                        name: eventName,
                        dataLines: dataLines,
                        onLog: onLog,
                        onSample: onSample
                    )
                    eventName = ""
                    dataLines.removeAll(keepingCapacity: true)
                    continue
                }

                if line.hasPrefix(":") {
                    continue
                }

                let (field, value) = parseSSEField(line)

                switch field {
                case "event":
                    eventName = value
                case "data":
                    dataLines.append(value)
                default:
                    break
                }
            } else if byte == 0x0A {
                if previousWasCarriageReturn {
                    previousWasCarriageReturn = false
                    continue
                }

                let line = decodeSSELine(from: lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)

                if line.isEmpty {
                    try await handleEvent(
                        name: eventName,
                        dataLines: dataLines,
                        onLog: onLog,
                        onSample: onSample
                    )
                    eventName = ""
                    dataLines.removeAll(keepingCapacity: true)
                    continue
                }

                if line.hasPrefix(":") {
                    continue
                }

                let (field, value) = parseSSEField(line)

                switch field {
                case "event":
                    eventName = value
                case "data":
                    dataLines.append(value)
                default:
                    break
                }
            } else {
                previousWasCarriageReturn = false
                lineBuffer.append(byte)
            }
        }
    }

    private func handleEvent(
        name: String,
        dataLines: [String],
        onLog: @escaping @Sendable (String) -> Void,
        onSample: @escaping @Sendable (TelemetrySample) async -> Void
    ) async throws {
        guard !dataLines.isEmpty else {
            return
        }

        let data = Data(dataLines.joined(separator: "\n").utf8)

        switch name {
        case "gpu_telemetry":
            onLog("Received gpu_telemetry event.")
            let sample = try TelemetryParser.firstSample(from: data)
            await onSample(sample)

        case "error":
            onLog("Received error event from telemetry stream.")
            if let errorResponse = try? JSONDecoder().decode(DashboardErrorResponse.self, from: data) {
                throw DashboardError.server(errorResponse.error)
            }
            throw DashboardError.server("The telemetry stream returned an error.")

        default:
            if !name.isEmpty {
                onLog("Ignored SSE event '\(name)'.")
            }
            break
        }
    }

    private func endpoint(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private func decodeSSELine(from bytes: [UInt8]) -> String {
        var bytes = bytes

        if bytes.last == 0x0D {
            bytes.removeLast()
        }

        return String(decoding: bytes, as: UTF8.self)
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
