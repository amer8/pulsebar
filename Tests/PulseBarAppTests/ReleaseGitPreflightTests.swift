import Foundation
import XCTest

@testable import PulseBarTools

final class ReleaseGitPreflightTests: XCTestCase {
    func testAllowsMainAheadOfRemoteAndRejectsOtherBranches() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.commit("first")
        try fixture.git(["push", "-u", "origin", "main"])
        try fixture.commit("release")
        XCTAssertNoThrow(try ReleaseGitPreflight.validate(root: fixture.local))

        try fixture.git(["checkout", "-b", "feature"])
        XCTAssertThrowsError(try ReleaseGitPreflight.validate(root: fixture.local))
        try fixture.git(["checkout", "--detach"])
        XCTAssertThrowsError(try ReleaseGitPreflight.validate(root: fixture.local))
    }

    func testRejectsRemoteChangesNotInLocalMain() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.commit("first")
        try fixture.git(["push", "-u", "origin", "main"])
        try fixture.git(["clone", fixture.remote.path, fixture.other.path], at: fixture.root)
        try fixture.git(["checkout", "main"], at: fixture.other)
        try fixture.git(["config", "user.email", "test@example.invalid"], at: fixture.other)
        try fixture.git(["config", "user.name", "Test"], at: fixture.other)
        try "remote".write(to: fixture.other.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        try fixture.git(["add", "remote.txt"], at: fixture.other)
        try fixture.git(["commit", "-m", "remote"], at: fixture.other)
        try fixture.git(["push", "origin", "main"], at: fixture.other)

        XCTAssertThrowsError(try ReleaseGitPreflight.validate(root: fixture.local))
    }
}

private struct GitFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulsebar-release-test-\(UUID().uuidString)")
    var local: URL { root.appendingPathComponent("local") }
    var remote: URL { root.appendingPathComponent("remote.git") }
    var other: URL { root.appendingPathComponent("other") }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--bare", "--initial-branch=main", remote.path], at: root)
        try git(["init", "--initial-branch=main", local.path], at: root)
        try git(["config", "user.email", "test@example.invalid"])
        try git(["config", "user.name", "Test"])
        try git(["remote", "add", "origin", remote.path])
    }

    func commit(_ name: String) throws {
        try name.write(to: local.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        try git(["add", "\(name).txt"])
        try git(["commit", "-m", name])
    }

    func git(_ arguments: [String], at directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? local
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitFixture", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: arguments.joined(separator: " ")])
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
