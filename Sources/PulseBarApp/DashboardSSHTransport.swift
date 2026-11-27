import Darwin
import Foundation

/// SSH authenticates the host before it starts this fixed command. The remote ready
/// line keeps passwords and tokens out of both command lines and the pre-authentication exchange.
struct DashboardSSHTransport: Sendable {
    static let ready = "PulseBar-SSH/1"
    // -q ignores the remote curlrc. Each request starts without cookies, and Swift checks every redirect.
    static let remoteCommand =
        "printf 'PulseBar-SSH/1\\n'; exec /usr/bin/curl -q --silent --no-buffer --globoff --noproxy '*' --proto '=http' --http1.1 --include --config -"

    let origin: URL
    private let makeProcess: @Sendable () async throws -> Process

    init(endpoint: DashboardEndpoint, config: URL? = nil) {
        self.init(origin: endpoint.url) {
            guard let host = endpoint.sshHost else {
                throw DashboardError.server(DashboardConnectionMessage.missingConnection)
            }
            // The normal OpenSSH lookup checks permissions on ~/.ssh/config. Tests supply a private config.
            let configArguments = config.map { ["-F", $0.path] } ?? []
            try await Self.requireConfiguredAlias(host, configArguments: configArguments)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments =
                configArguments + DashboardEndpoint.verifiedSSHArguments(for: host) + [
                    "-T", "-a", "-x",
                    "-o", "SessionType=default", "-o", "StdinNull=no", "-o", "ForkAfterAuthentication=no",
                    "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes",
                    "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none", "-o", "EscapeChar=none",
                    "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                    "--", host, Self.remoteCommand,
                ]
            return process
        }
    }

    init(origin: URL, makeProcess: @escaping @Sendable () async throws -> Process) {
        self.origin = origin
        self.makeProcess = makeProcess
    }

    // Let OpenSSH interpret Host, Match and Include. An unmatched name would otherwise
    // be treated as a DNS name. An alias equal to its HostName can set HostKeyAlias explicitly.
    static func requireConfiguredAlias(_ host: String, configArguments: [String] = []) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = configArguments + ["-G", "-v", "-T", "--", host]
        let exchange = DashboardSSHExchange(process: process, includeConfigTrace: true)
        try await withTaskCancellationHandler {
            try await exchange.start()
            let deadline = exchange.startupDeadline()
            defer {
                deadline.cancel()
                exchange.cancel()
            }
            let reader = DashboardResponseReader(exchange: exchange, stage: .configuration)
            var matchedLiteral = false
            while let line = try await reader.line(limit: 64 * 1024) {
                if line.hasPrefix("debug1: "), let marker = line.range(of: ": Applying options for "),
                    line[marker.upperBound...].caseInsensitiveCompare(host) == .orderedSame
                {
                    matchedLiteral = true
                }
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                if (parts[0] == "hostname" && parts[1].lowercased() != host.lowercased())
                    || (parts[0] == "hostkeyalias" && parts[1].lowercased() == host.lowercased())
                {
                    return
                }
            }
            // An explicit "Host spark.local" can legitimately use its own name as HostName.
            guard matchedLiteral else {
                throw DashboardError.server(DashboardConnectionMessage.missingConnection)
            }
        } onCancel: {
            exchange.cancel()
        }
    }

    func withResponse<T>(
        to original: URLRequest, _ consume: (Int, DashboardResponseReader) async throws -> T
    ) async throws -> T {
        var request = original
        for _ in 0..<8 {
            try Task.checkCancellation()
            guard let url = request.url, sameOrigin(url) else { throw DashboardError.invalidResponse }
            let exchange = DashboardSSHExchange(process: try await makeProcess())
            let result: HTTPResult<T> = try await withTaskCancellationHandler {
                try await exchange.start()
                let deadline = exchange.startupDeadline()
                defer {
                    deadline.cancel()
                    exchange.cancel()
                }
                let reader = DashboardResponseReader(exchange: exchange)
                guard try await reader.line(limit: 128) == Self.ready else {
                    throw DashboardError.server(
                        "SSH could not verify or connect to the dashboard host. Check the alias, trusted host key and SSH login.")
                }
                reader.stage = .request
                try await exchange.send(Self.curlConfiguration(request))
                let (status, location) = try await reader.headers()
                deadline.cancel()
                if [301, 302, 303, 307, 308].contains(status), let location {
                    guard let target = URL(string: location, relativeTo: url)?.absoluteURL, sameOrigin(target) else {
                        throw DashboardError.invalidResponse
                    }
                    var next = request
                    next.url = target
                    if (status == 303 && next.httpMethod != "HEAD") || ([301, 302].contains(status) && next.httpMethod == "POST") {
                        next.httpMethod = "GET"
                        next.httpBody = nil
                        next.setValue(nil, forHTTPHeaderField: "Content-Type")
                    }
                    return .redirect(next)
                }
                return .value(try await consume(status, reader))
            } onCancel: {
                exchange.cancel()
            }
            switch result {
            case .value(let value): return value
            case .redirect(let next): request = next
            }
        }
        throw DashboardError.invalidResponse
    }

    private enum HTTPResult<T> {
        case redirect(URLRequest)
        case value(T)
    }

    private func sameOrigin(_ url: URL) -> Bool {
        url.scheme == origin.scheme && url.host == origin.host && (url.port ?? 80) == (origin.port ?? 80)
            && url.user == nil && url.password == nil
    }

    // curl's quoted config syntax is parsed by curl on stdin, never by a shell.
    private static func curlConfiguration(_ request: URLRequest) -> Data {
        func quoted(_ value: String) -> String {
            "\""
                + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\""
        }
        var lines = ["url = " + quoted(request.url!.absoluteString), "connect-timeout = 5"]
        if request.value(forHTTPHeaderField: "Accept") != "text/event-stream" {
            lines.append("max-time = \(Int(request.timeoutInterval))")
        }
        if request.httpMethod == "HEAD" { lines.append("head") }
        for (name, value) in request.allHTTPHeaderFields ?? [:] { lines.append("header = " + quoted("\(name): \(value)")) }
        if let body = request.httpBody { lines.append("data-binary = " + quoted(String(decoding: body, as: UTF8.self))) }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

private enum DashboardSSHStage { case configuration, authentication, request }

// Drain stderr concurrently so ssh cannot block on a full pipe. Keep only the
// diagnostic category; remote messages and config values never reach the UI or log.
private final class SSHDiagnostics: @unchecked Sendable {
    private enum Failure { case changedKey, unknownKey, login, unreachable }
    private let finished = DispatchGroup()
    private let lock = NSLock()
    private var failure: Failure?

    func drain(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async(group: finished) {
            var suffix = ""
            while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
                let text = suffix + String(decoding: chunk, as: UTF8.self).lowercased()
                suffix = String(text.suffix(128))
                self.lock.withLock {
                    if text.contains("remote host identification has changed") {
                        self.failure = .changedKey
                    } else if self.failure == nil {
                        if text.contains("host key verification failed") || text.contains("host key is known for") {
                            self.failure = .unknownKey
                        } else if text.contains("permission denied") {
                            self.failure = .login
                        } else if text.contains("could not resolve hostname") || text.contains("connection refused")
                            || text.contains("connection timed out")
                        {
                            self.failure = .unreachable
                        }
                    }
                }
            }
        }
    }

    func error(stage: DashboardSSHStage, status: Int32) -> DashboardError {
        if stage == .authentication {
            _ = finished.wait(timeout: .now() + .milliseconds(250))
            if lock.withLock({ failure }) == .unknownKey { return .unknownSSHHostKey }
        }
        return .server(message(stage: stage, status: status))
    }

    private func message(stage: DashboardSSHStage, status: Int32) -> String {
        switch stage {
        case .configuration: return "SSH could not read the host configuration. Check the alias in ~/.ssh/config."
        case .request:
            switch status {
            case 7: return "SSH connected. Check that the dashboard is running on the configured dashboard port."
            case 28: return "SSH connected, but the dashboard request timed out."
            case 127: return "SSH connected, but /usr/bin/curl could not start on the device."
            default: return "The dashboard request over SSH was interrupted."
            }
        case .authentication:
            switch lock.withLock({ failure }) {
            case .changedKey:
                return
                    "The SSH host key has changed. Verify the new fingerprint with your administrator before updating the trusted key."
            case .unknownKey:
                return
                    "SSH could not verify the host key. Confirm the fingerprint independently and enroll the key under the applied alias."
            case .login:
                return
                    "SSH login failed. Ask your administrator to authorize this Mac’s SSH public key for your SSH account. If your key has a passphrase, unlock it in your SSH agent, then connect again."
            case .unreachable: return "The SSH host is unreachable. Check its alias, address and network connection."
            case nil: return "SSH could not start the dashboard connection. Check the alias, trusted host key and noninteractive SSH login."
            }
        }
    }
}

// Blocking pipe I/O stays off the Swift cooperative executor. A cancelled task
// terminates its own SSH child, releasing its pipe readers even on a silent stream.
private final class DashboardSSHExchange: @unchecked Sendable {
    let process: Process
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let diagnostics = SSHDiagnostics()
    private let lock = NSLock()
    private var cancelled = false
    private let exited = DispatchGroup()

    private let includeConfigTrace: Bool
    init(process: Process, includeConfigTrace: Bool = false) {
        self.includeConfigTrace = includeConfigTrace
        self.process = process
        process.standardInput = input
        process.standardOutput = output
        process.standardError = includeConfigTrace ? output : errors
    }

    @MainActor func start() throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw DashboardError.invalidResponse }
            exited.enter()
            process.terminationHandler = { [exited] _ in exited.leave() }
            do {
                try process.run()
                if !includeConfigTrace { diagnostics.drain(errors.fileHandleForReading) }
            } catch {
                exited.leave()
                throw error
            }
        }
    }

    // ConnectTimeout covers SSH key exchange. Also bound authentication, remote shell
    // startup and HTTP response headers, while allowing an established SSE stream to stay open.
    func startupDeadline() -> Task<Void, Error> {
        Task {
            try await Task.sleep(for: .seconds(20))
            cancel()
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async { [input] in
                continuation.resume(
                    with: Result {
                        defer { try? input.fileHandleForWriting.close() }
                        try input.fileHandleForWriting.write(contentsOf: data)
                    })
            }
        }
    }

    func read(stage: DashboardSSHStage) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                continuation.resume(
                    with: Result {
                        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                        var count: Int
                        repeat {
                            count = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                        } while count < 0 && errno == EINTR
                        guard count >= 0 else { throw DashboardError.invalidResponse }
                        if count == 0 {
                            exited.wait()
                            guard process.terminationStatus == 0 else {
                                throw diagnostics.error(stage: stage, status: process.terminationStatus)
                            }
                        }
                        return Data(buffer.prefix(count))
                    })
            }
        }
    }
}

final class DashboardResponseReader {
    private let exchange: DashboardSSHExchange
    private var buffer = Data()
    private var index = 0

    fileprivate var stage: DashboardSSHStage

    fileprivate init(exchange: DashboardSSHExchange, stage: DashboardSSHStage = .authentication) {
        self.exchange = exchange
        self.stage = stage
    }

    func next() async throws -> UInt8? {
        if index == buffer.count {
            try Task.checkCancellation()
            buffer = try await exchange.read(stage: stage)
            index = 0
            if buffer.isEmpty { return nil }
        }
        defer { index += 1 }
        return buffer[index]
    }

    fileprivate func line(limit: Int) async throws -> String? {
        var bytes: [UInt8] = []
        while let byte = try await next() {
            if byte == 10 {
                if bytes.last == 13 { bytes.removeLast() }
                return String(decoding: bytes, as: UTF8.self)
            }
            guard bytes.count < limit else { throw DashboardError.invalidResponse }
            bytes.append(byte)
        }
        return nil
    }

    fileprivate func headers() async throws -> (Int, String?) {
        var remaining = 64 * 1024
        while remaining > 0 {
            guard let statusLine = try await line(limit: remaining), statusLine.hasPrefix("HTTP/1."),
                let code = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }), (100...599).contains(code)
            else { throw DashboardError.invalidResponse }
            remaining -= statusLine.utf8.count + 2
            var location: String?
            while remaining > 0, let header = try await line(limit: remaining) {
                remaining -= header.utf8.count + 2
                if header.isEmpty {
                    if code >= 200 { return (code, location) }
                    break
                }
                if let colon = header.firstIndex(of: ":"), header[..<colon].lowercased() == "location" {
                    location = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            if code >= 200 { break }
        }
        throw DashboardError.invalidResponse
    }
}
