import Foundation
import XCTest

@testable import PulseBarApp

@MainActor
final class DGXConnectionSetupTests: XCTestCase {
    private func connections() throws -> SavedSSHConnections {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: dir) }
        return SavedSSHConnections(config: dir.appendingPathComponent("config"))
    }

    func testPickerCollectsLiteralAliasesAndTerminatesRecursiveIncludes() throws {
        let store = try connections()
        try """
        Host = lab "spark one" SPARK !excluded gpu-*
        Include "saved hosts/*.conf"
        Host *
        """.write(to: store.config, atomically: true, encoding: .utf8)
        let child = store.directory.appendingPathComponent("saved hosts")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try "Include config\nhOsT=spark backup\n".write(to: child.appendingPathComponent("dgx.conf"), atomically: true, encoding: .utf8)
        let included = child.appendingPathComponent("dgx.conf")
        let original = try Data(contentsOf: store.config)
        let originalInclude = try Data(contentsOf: included)
        XCTAssertEqual(store.aliases(), ["backup", "lab", "SPARK"])
        XCTAssertEqual(try Data(contentsOf: store.config), original)
        XCTAssertEqual(try Data(contentsOf: included), originalInclude)
    }

    func testDiscoveryDoesNotCreateMissingSSHDirectoryOrConfig() throws {
        let root = try connections().directory
        let ssh = root.appendingPathComponent(".ssh")
        let store = SavedSSHConnections(config: ssh.appendingPathComponent("config"))
        XCTAssertEqual(store.aliases(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ssh.path))
    }

    func testOnlyAliasChooserDiscoversHostsAndRefreshesAfterExternalSetup() async throws {
        let store = try connections()
        let setup = DGXConnectionSetup()
        for step in [setup.step, .verify("SHA256:test")] {
            setup.reset(to: step)
            await setup.loadAliases {
                XCTFail("Discovery outside the alias chooser")
                return []
            }
            XCTAssertNil(setup.savedAliases)
        }
        setup.reset(to: .chooseAlias)
        await setup.loadAliases { store.aliases() }
        XCTAssertEqual(setup.savedAliases, [])
        try "Host new-device".write(to: store.config, atomically: true, encoding: .utf8)
        await setup.loadAliases { store.aliases() }
        XCTAssertEqual(setup.savedAliases, ["new-device"])
        setup.reset()
        XCTAssertNil(setup.savedAliases)
    }

    func testOpenSSHAcceptsExplicitSameNameHostButIgnoresInactiveInclude() async throws {
        let store = try connections()
        let child = store.directory.appendingPathComponent("conditional")
        try "Host inactive.local\n".write(to: child, atomically: true, encoding: .utf8)
        try """
        Host spark.local
            User fixture
        Host special
            Include "\(child.path)"
        """.write(to: store.config, atomically: true, encoding: .utf8)
        let args = ["-F", store.config.path]
        try await DashboardSSHTransport.requireConfiguredAlias("spark.local", configArguments: args)
        do {
            try await DashboardSSHTransport.requireConfiguredAlias("inactive.local", configArguments: args)
            XCTFail("An inactive Include is not an effective SSH connection")
        } catch { XCTAssertTrue(error.userFacingMessage.contains(DashboardConnectionMessage.missingConnection)) }
    }

    func testDiscoveryPreservesSymlinkedConfiguration() throws {
        let store = try connections()
        let managed = store.directory.appendingPathComponent("managed")
        try "Host existing\n".write(to: managed, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: store.config, withDestinationURL: managed)
        XCTAssertEqual(store.aliases(), ["existing"])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: store.config.path), managed.path)
        XCTAssertEqual(try String(contentsOf: managed, encoding: .utf8), "Host existing\n")
    }

    func testEditingWhileCheckingCannotApplyAnOldDestination() async throws {
        var resume: CheckedContinuation<Bool, Never>?
        let setup = DGXConnectionSetup(probe: { _ in await withCheckedContinuation { resume = $0 } })
        let target = try DashboardEndpoint(port: 11000, sshHost: "lab")
        let task = try XCTUnwrap(setup.connect(target) { _ in XCTFail("Applied a cancelled check") })
        while resume == nil { await Task.yield() }
        setup.reset(to: .chooseAlias)
        resume?.resume(returning: true)
        await task.value
        XCTAssertEqual(setup.step, .chooseAlias)
        XCTAssertNil(setup.feedback)
        XCTAssertFalse(setup.busy)
    }
}
