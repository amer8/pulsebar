import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import PulseBarApp

@MainActor
final class DashboardSSHTransportTests: XCTestCase {
    func testDashboardCredentialsRequireAnEnrolledSSHHostKey() async throws {
        let dashboard = try await DashboardFixture(scenario: .live, firstStreamBody: Data(": heartbeat\n\n".utf8))
        defer { dashboard.stop() }
        let (config, sshPort) = try startSSHServer()
        let directory = config.deletingLastPathComponent()
        let knownHosts = directory.appendingPathComponent("known_hosts")
        let endpoint = try DashboardEndpoint(port: XCTUnwrap(dashboard.url.port), sshHost: "dgx-test")
        let client = DashboardClient(transport: DashboardSSHTransport(endpoint: endpoint, config: config))
        let differentKey = try String(contentsOf: directory.appendingPathComponent("identity.pub"), encoding: .utf8)
        let trustedKey = try String(contentsOf: directory.appendingPathComponent("host.pub"), encoding: .utf8)
        // A trusted key filed only under the resolved address must not authorize this alias.
        let trustedAddress = "[127.0.0.1]:\(sshPort) " + trustedKey
        for entries in ["", "dgx-test " + differentKey + trustedAddress] {
            try entries.write(to: knownHosts, atomically: true, encoding: .utf8)
            await assertSSHRejection(containing: entries.isEmpty ? "fingerprint independently" : "host key has changed") {
                _ = try await client.login(username: "demo", password: "demo")
            }
            await assertSSHRejection { _ = try await client.updateAvailability(token: "simulator-token") }
            await assertSSHRejection { try await client.consumeTelemetryStream(token: "simulator-token", onSample: { _ in }) }
            XCTAssertTrue(dashboard.requests.isEmpty)
            XCTAssertEqual(try String(contentsOf: knownHosts, encoding: .utf8), entries)
        }

        try ("dgx-test " + trustedKey).write(to: knownHosts, atomically: true, encoding: .utf8)
        let reachable = try await client.checkConnection()
        XCTAssertTrue(reachable)
        let token = try await client.login(username: "demo", password: "demo")
        XCTAssertEqual(token, "simulator-token")
        let availability = try await client.updateAvailability(token: token)
        XCTAssertFalse(availability.available)
        try await client.consumeTelemetryStream(token: token, onSample: { _ in })
        XCTAssertEqual(dashboard.requests.map(\.path), ["/", "/api/login", "/api/v1/updates/available", "/api/v1/gpu_telemetry/stream"])
        XCTAssertEqual(
            dashboard.requests.suffix(2).map { $0.headers["authorization"] }, Array(repeating: "Bearer simulator-token", count: 2))

        let successfulRequests = dashboard.requests.count
        let directConfig = try String(contentsOf: config, encoding: .utf8)
        let wrongIdentity = directConfig.replacingOccurrences(of: "/identity\"", with: "/host\"")
        try wrongIdentity.write(to: config, atomically: true, encoding: .utf8)
        await assertSSHRejection(containing: "SSH login failed") { _ = try await client.checkConnection() }
        XCTAssertEqual(dashboard.requests.count, successfulRequests)

        // macOS also has a separate host-verification exception for ProxyCommand.
        try (directConfig + "\n    ProxyCommand /usr/bin/nc %h %p\n").write(to: config, atomically: true, encoding: .utf8)
        try "".write(to: knownHosts, atomically: true, encoding: .utf8)
        await assertSSHRejection { _ = try await client.login(username: "demo", password: "demo") }
        XCTAssertEqual(dashboard.requests.count, successfulRequests)
        try ("dgx-test " + trustedKey).write(to: knownHosts, atomically: true, encoding: .utf8)
        let proxied = try await client.checkConnection()
        XCTAssertTrue(proxied)

    }

    func testGuidedSetupEnrollsOnlyTheIndependentlyMatchedKeyBeforeSignIn() async throws {
        let dashboard = try await DashboardFixture(scenario: .live)
        defer { dashboard.stop() }
        let port = try XCTUnwrap(dashboard.url.port)
        let config = try startSSHServer().config
        let directory = config.deletingLastPathComponent()
        let known = directory.appendingPathComponent("known_hosts")
        let originalConfig = try Data(contentsOf: config)
        try Data().write(to: known)
        let store = SavedSSHConnections(config: config)
        let alias = "dgx-test"
        let target = try DashboardEndpoint(port: port, sshHost: alias)
        let client = DashboardClient(transport: DashboardSSHTransport(endpoint: target, config: config))
        func trustedFingerprint(_ name: String) throws -> String {
            let key = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let decoded = try XCTUnwrap(Data(base64Encoded: String(key.split(separator: " ")[1])))
            return "SHA256:" + Data(SHA256.hash(data: decoded)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        }
        let expected = try trustedFingerprint("host.pub")
        let other = try trustedFingerprint("identity.pub")
        let original = try Data(contentsOf: known)
        let enrollment = SSHHostEnrollment(host: alias, config: config)
        let setup = DGXConnectionSetup(
            probe: { _ in try await client.checkConnection() },
            fingerprint: { _, match in try await enrollment.presentedFingerprint(confirming: match) })
        setup.reset(to: .chooseAlias)
        await setup.loadAliases { store.aliases() }
        var applied: [DashboardEndpoint] = []
        await setup.connect(target) { applied.append($0) }?.value
        XCTAssertEqual(setup.step, .verify(expected), setup.feedback?.message ?? "")
        XCTAssertTrue(applied.isEmpty)
        XCTAssertNil(setup.connect(target, expected: other) { applied.append($0) })
        do {
            _ = try await enrollment.presentedFingerprint(confirming: other)
            XCTFail("OpenSSH must reject the wrong fingerprint")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: known), original)
        XCTAssertTrue(dashboard.requests.isEmpty)
        await setup.connect(target, expected: expected) { applied.append($0) }?.value
        XCTAssertEqual(applied, [target], setup.feedback?.message ?? "")
        XCTAssertEqual(dashboard.requests.map(\.method), ["HEAD"])
        let token = try await client.login(username: "demo", password: "demo")
        XCTAssertEqual(token, "simulator-token")

        // The saved connection now passes a strict check without asking for the key again.
        await setup.connect(target) { applied.append($0) }?.value
        XCTAssertEqual(applied, [target, target])
        let requests = dashboard.requests.count
        let differentKey = try String(contentsOf: directory.appendingPathComponent("identity.pub"), encoding: .utf8)
        let changed = "\(alias) " + differentKey
        try changed.write(to: known, atomically: true, encoding: .utf8)
        await setup.connect(target) { applied.append($0) }?.value
        XCTAssertEqual(setup.step, .choose)
        XCTAssertTrue(setup.feedback?.message.contains("host key has changed") == true)
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(try String(contentsOf: known, encoding: .utf8), changed)
        XCTAssertEqual(dashboard.requests.count, requests)
        XCTAssertEqual(try Data(contentsOf: config), originalConfig)
    }

    func testPasswordIsWrittenOnlyAfterTheRemoteReadyLine() async throws {
        let dashboard = try await DashboardFixture(scenario: .live)
        defer { dashboard.stop() }
        let transport = DashboardSSHTransport(origin: dashboard.url) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            // Exit before the ready line if the client writes any part of a curl request early.
            process.arguments = ["-c", "if IFS= read -r -t 1; then exit 1; fi\n" + DashboardSSHTransport.remoteCommand]
            return process
        }
        let password = "quote \" and backslash \\ and newline\n"
        do {
            _ = try await DashboardClient(transport: transport).login(username: "demo", password: password)
            XCTFail("Fixture accepted unexpected credentials")
        } catch DashboardError.loginFailed {}
        let request = try XCTUnwrap(dashboard.requests.first)
        let credentials = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: String])
        XCTAssertEqual(credentials, ["username": "demo", "password": password])
    }

    func testMissingAliasOrUnconfiguredHostnameCannotUseTheLocalDashboard() async throws {
        let dashboard = try await DashboardFixture(scenario: .live)
        defer { dashboard.stop() }
        for host in [nil, "127.0.0.1"] {
            let endpoint = try DashboardEndpoint(port: XCTUnwrap(dashboard.url.port), sshHost: host)
            let client = DashboardClient(transport: DashboardSSHTransport(endpoint: endpoint, config: URL(fileURLWithPath: "/dev/null")))
            await assertSSHRejection { _ = try await client.login(username: "demo", password: "demo") }
        }
        XCTAssertTrue(dashboard.requests.isEmpty)
    }

    func testRemoteDashboardFailureIsDistinctFromSSHTrustFailure() async throws {
        let transport = DashboardSSHTransport(origin: DashboardEndpoint.standard.url) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "echo PulseBar-SSH/1; /bin/cat > /dev/null; exit 7"]
            return process
        }
        await assertSSHRejection(containing: "dashboard is running on the configured dashboard port") {
            _ = try await DashboardClient(transport: transport).checkConnection()
        }
    }

    private func startSSHServer() throws -> (config: URL, port: UInt16) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        for name in ["host", "identity"] {
            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", directory.appendingPathComponent(name).path]
            try keygen.run()
            keygen.waitUntilExit()
            XCTAssertEqual(keygen.terminationStatus, 0)
        }

        let daemonConfig = directory.appendingPathComponent("sshd_config")
        try """
        HostKey "\(directory.path)/host"
        AuthorizedKeysFile "\(directory.path)/identity.pub"
        AuthenticationMethods publickey
        AllowTcpForwarding no
        PermitTTY no
        PermitUserRC no
        StrictModes yes
        UsePAM no
        """.write(to: daemonConfig, atomically: true, encoding: .utf8)
        let listener = try SSHTestListener(configuration: daemonConfig)
        addTeardownBlock { @MainActor in listener.stop() }

        let config = directory.appendingPathComponent("ssh_config")
        let knownHosts = directory.appendingPathComponent("known_hosts")
        try """
        Host dgx-test
            HostName 127.0.0.1
            Port \(listener.port)
            User \(NSUserName())
            IdentityFile "\(directory.path)/identity"
            IdentityAgent none
            IdentitiesOnly yes
            UserKnownHostsFile "\(knownHosts.path)"
            GlobalKnownHostsFile /dev/null
            StrictHostKeyChecking no
            NoHostAuthenticationForLocalhost yes
            NoHostAuthenticationForProxyCommand yes
        """.write(to: config, atomically: true, encoding: .utf8)
        let hostKey = try String(contentsOf: directory.appendingPathComponent("host.pub"), encoding: .utf8)
        try ("dgx-test " + hostKey).write(to: knownHosts, atomically: true, encoding: .utf8)
        return (config, listener.port)
    }

    private func assertSSHRejection(
        containing text: String = "SSH", _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected SSH to reject the connection", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription, file: file, line: line)
        }
    }
}

// Hand connected loopback sockets to OpenSSH's inetd mode. The OS assigns the port.
// Each sshd authenticates only the disposable test identity, using the supplied host key.
private final class SSHTestListener {
    let port: UInt16
    private let source: DispatchSourceRead

    init(configuration: URL) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        do {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var size = socklen_t(address.sin_len)
            try withUnsafeMutablePointer(to: &address) {
                try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    guard bind(fd, pointer, size) == 0, listen(fd, 8) == 0, getsockname(fd, pointer, &size) == 0,
                        fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0
                    else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                }
            }
            port = UInt16(bigEndian: address.sin_port)
        } catch {
            close(fd)
            throw error
        }

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "PulseBarTests.SSH"))
        source.setCancelHandler { close(fd) }
        source.setEventHandler {
            let peer = accept(fd, nil, nil)
            guard peer >= 0 else { return }
            let socket = FileHandle(fileDescriptor: peer, closeOnDealloc: true)
            let daemon = Process()
            daemon.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            daemon.arguments = ["-i", "-e", "-f", configuration.path]
            daemon.standardInput = socket
            daemon.standardOutput = socket
            daemon.standardError = FileHandle.nullDevice
            do { try daemon.run() } catch { XCTFail("Unable to start SSH test server: \(error)") }
            try? socket.close()
        }
        source.resume()
    }

    func stop() { source.cancel() }
}
