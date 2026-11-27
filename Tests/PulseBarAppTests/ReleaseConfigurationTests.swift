import Foundation
import XCTest

@testable import PulseBarTools

final class ReleaseConfigurationTests: XCTestCase {
    func testBundleReleaseDateIsValidatedBeforeWritingPlist() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let packaging = directory.appendingPathComponent("Packaging")
        try FileManager.default.createDirectory(at: packaging, withIntermediateDirectories: false)
        for file in ["Info.plist", "set-release-date.sh"] {
            try FileManager.default.copyItem(
                at: project.appendingPathComponent("Packaging/\(file)"), to: packaging.appendingPathComponent(file))
        }
        let build = directory.appendingPathComponent(".build/release")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data().write(to: build.appendingPathComponent("PulseBar"))
        let plist = build.appendingPathComponent("PulseBar.app/Contents/Info.plist")
        let changelog = directory.appendingPathComponent("CHANGELOG.md")
        let arguments = [
            "-f", project.appendingPathComponent("Makefile").path, "-o", "release", "bundle", "SKIP_ICON=1", "APP_VERSION=1.0",
        ]
        func storedDate() throws -> String? {
            let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
            return values?["PulseBarReleaseDate"] as? String
        }
        try "## 1.0 - 2026-11-24\n".write(to: changelog, atomically: true, encoding: .utf8)
        _ = try Command.capture("/usr/bin/make", arguments, cwd: directory, environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(try storedDate(), "2026-11-24")
        for heading in ["## 1.0 - \"untrusted\"", "## 1.0 - 2026-11-24 trailing"] {
            try heading.write(to: changelog, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try Command.capture("/usr/bin/make", arguments, cwd: directory, environment: ["PATH": "/usr/bin:/bin"]))
        }
    }

    func testPlistVersionsMatchVersionEnvironment() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lines = try String(contentsOf: root.appendingPathComponent("version.env"), encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        let values = Dictionary(
            uniqueKeysWithValues: lines.compactMap { line -> (String, String)? in
                let pair = line.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { return nil }
                return (String(pair[0]), String(pair[1]))
            })
        let data = try Data(contentsOf: root.appendingPathComponent("Packaging/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(plist["CFBundleShortVersionString"] as? String), try XCTUnwrap(values["MARKETING_VERSION"]))
        XCTAssertEqual(try XCTUnwrap(plist["CFBundleVersion"] as? String), try XCTUnwrap(values["BUILD_NUMBER"]))
    }

    func testCaptureHandlesLargeStdoutAndStderr() throws {
        let output = try Command.capture(
            "/bin/sh", ["-c", "head -c 1048576 /dev/zero; head -c 1048576 /dev/zero >&2"])
        XCTAssertEqual(output.utf8.count, 1_048_576)
    }

    func testAppcastVerificationRequiresMatchingSignedItem() throws {
        let xml = """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
              <item><sparkle:shortVersionString>1.0</sparkle:shortVersionString><sparkle:version>2</sparkle:version>
                <enclosure url="https://example.com/PulseBar-1.0.zip" length="4"/></item>
              <item><sparkle:shortVersionString>0.9</sparkle:shortVersionString><sparkle:version>1</sparkle:version>
                <enclosure url="https://example.com/PulseBar-0.9.zip" length="4" sparkle:edSignature="old"/></item>
            </channel></rss>
            """
        XCTAssertThrowsError(try AppcastVerifier.verify(Data(xml.utf8), version: "1.0", buildNumber: "2", archiveSize: 4))
        let signed = xml.replacingOccurrences(of: "length=\"4\"/>", with: "length=\"4\" sparkle:edSignature=\"new\"/>")
        XCTAssertNoThrow(try AppcastVerifier.verify(Data(signed.utf8), version: "1.0", buildNumber: "2", archiveSize: 4))
        XCTAssertThrowsError(try AppcastVerifier.verify(Data(signed.utf8), version: "1.0", buildNumber: "3", archiveSize: 4))
        XCTAssertThrowsError(try AppcastVerifier.verify(Data(signed.utf8), version: "1.0", buildNumber: "2", archiveSize: 5))
        XCTAssertThrowsError(try AppcastVerifier.verify(Data("<rss>".utf8), version: "1.0"))
    }

    @MainActor
    func testAppcastCanBeGeneratedWithoutChangingCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulsebar-appcast-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "<rss><channel/></rss>"
        try original.write(to: root.appendingPathComponent("appcast.xml"), atomically: true, encoding: .utf8)
        try "## 1.0\n\n- Release notes\n".write(
            to: root.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("PulseBar-1.0.zip")
        try Data("test".utf8).write(to: zip)
        let key = root.appendingPathComponent("key")
        try "test-key".write(to: key, atomically: true, encoding: .utf8)
        let generator = root.appendingPathComponent("generator")
        let script = """
            #!/bin/sh
            for work in "$@"; do :; done
            cat > "$work/appcast.xml" <<'XML'
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
            <sparkle:shortVersionString>1.0</sparkle:shortVersionString><sparkle:version>2</sparkle:version>
            <enclosure url="https://example.com/PulseBar-1.0.zip" length="4" sparkle:edSignature="signed"/>
            </item></channel></rss>
            XML
            """
        try script.write(to: generator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: generator.path)
        let staged = root.appendingPathComponent("staged.xml")
        let tool = Tool(root: root, environment: ["SPARKLE_PRIVATE_KEY_FILE": key.path, "GENERATE_APPCAST": generator.path])
        try tool.makeAppcast([zip.path], output: staged)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("appcast.xml"), encoding: .utf8), original)
        XCTAssertNoThrow(try AppcastVerifier.verify(Data(contentsOf: staged), version: "1.0", buildNumber: "2", archiveSize: 4))
    }
}
