import Foundation
import Network

// Mutable state and Network callbacks stay on queue; stop() synchronizes with that queue.
final class DashboardFixture: @unchecked Sendable {
    enum Scenario: String {
        case live
        case heartbeatOnly = "heartbeat-only"
        case unauthorized
        case loginError = "login-error"
        case loginInvalidResponse = "login-invalid-response"
    }

    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }
    private let scenario: Scenario
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PulseBarTests.DashboardFixture")
    private var startup: CheckedContinuation<Void, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var timers: [UUID: DispatchSourceTimer] = [:]
    private var stopped = false

    init(scenario: Scenario) async throws {
        self.scenario = scenario
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, let continuation = self.startup else { return }
                switch state {
                case .ready:
                    self.startup = nil
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    self.startup = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    self.startup = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            listener.cancel()
            for timer in timers.values { timer.cancel() }
            timers.removeAll()
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    deinit {
        listener.cancel()
        for timer in timers.values { timer.cancel() }
        for connection in connections.values { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(id)
            default: break
            }
        }
        connection.start(queue: queue)
        receiveRequest(id)
    }

    private func receiveRequest(_ id: UUID, buffered: Data = Data()) {
        connections[id]?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffered = buffered
            buffered.append(data ?? Data())
            guard buffered.count <= 8192, error == nil else {
                self.close(id)
                return
            }
            if let boundary = buffered.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: buffered[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let request = lines[0].split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                guard request.count == 3, (0...4096).contains(length) else {
                    self.close(id)
                    return
                }
                if buffered.count - boundary.upperBound >= length {
                    let body = Data(buffered[boundary.upperBound...].prefix(length))
                    self.respond(id, method: String(request[0]), path: String(request[1]), headers: headers, body: body)
                    return
                }
            }
            if complete { self.close(id) } else { self.receiveRequest(id, buffered: buffered) }
        }
    }

    private func respond(_ id: UUID, method: String, path: String, headers: [String: String], body: Data) {
        if method == "POST", path == "/api/login" {
            let credentials = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            guard credentials == ["username": "demo", "password": "demo"] else {
                respondJSON(id, status: 401, payload: ["error": "Invalid credentials"])
                return
            }
            switch scenario {
            case .loginError:
                respondJSON(id, status: 503, payload: ["error": "Authentication service unavailable."])
            case .loginInvalidResponse:
                respondJSON(id, payload: ["unexpected": "missing token"])
            default:
                respondJSON(id, payload: ["token": "simulator-token"])
            }
            return
        }
        guard method == "GET" else {
            respondJSON(id, status: 404, payload: ["error": "Not found"])
            return
        }
        if path == "/" {
            respondJSON(id, payload: ["dashboard": "PulseBar test fixture"])
            return
        }
        guard headers["authorization"] == "Bearer simulator-token", scenario != .unauthorized else {
            respondJSON(id, status: 401, payload: ["error": "Session expired"])
            return
        }
        switch path {
        case "/api/v1/updates/available":
            respondJSON(id, payload: ["available": false])
        case "/api/v1/gpu_telemetry/stream":
            startStream(id)
        default:
            respondJSON(id, status: 404, payload: ["error": "Not found"])
        }
    }

    private func respondJSON(_ id: UUID, status: Int = 200, payload: [String: Any]) {
        let body = try! JSONSerialization.data(withJSONObject: payload)
        let reason = [200: "OK", 401: "Unauthorized", 404: "Not Found", 503: "Service Unavailable"][status]!
        let headers =
            "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connections[id]?.send(content: Data(headers.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }

    private func startStream(_ id: UUID) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        connections[id]?.send(
            content: Data(headers.utf8),
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                guard error == nil, self.connections[id] != nil else {
                    self.close(id)
                    return
                }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .seconds(1))
                timer.setEventHandler { [weak self] in self?.sendEvent(id) }
                self.timers[id] = timer
                timer.resume()
            })
    }

    private func sendEvent(_ id: UUID) {
        let event: String
        if scenario == .heartbeatOnly {
            event = ": heartbeat\n\n"
        } else {
            let payload =
                "{\"TelemetryForGPUs\":[{\"percentage_utilization\":37,\"memory_total_in_kib\":134217728,\"memory_available_in_kib\":67108864}]}"
            event = "event: gpu_telemetry\ndata: \(payload)\n\n"
        }
        connections[id]?.send(
            content: Data(event.utf8),
            completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close(id) }
            })
    }

    private func close(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
}
