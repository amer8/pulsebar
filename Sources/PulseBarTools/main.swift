import AppKit
import Darwin
import Foundation
import PulseBarUI
import SwiftUI

@main
@MainActor
enum PulseBarTools {
    static func main() {
        do {
            try Tool().run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as ToolError {
            FileHandle.standardError.writeLine("ERROR: \(error.message)")
            Darwin.exit(1)
        } catch {
            FileHandle.standardError.writeLine("ERROR: \(error)")
            Darwin.exit(1)
        }
    }
}

@MainActor
private struct Tool {
    let root: URL
    let environment: [String: String]

    init() throws {
        root = try ProjectRoot.find()
        environment = ProcessInfo.processInfo.environment
    }

    func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printUsage()
            throw ToolError("missing command")
        }

        let rest = Array(arguments.dropFirst())
        switch command {
        case "changelog-to-html":
            try changelogToHTML(rest)
        case "check-release-assets":
            try checkReleaseAssets(rest)
        case "generate-release-notes":
            try generateReleaseNotes(rest)
        case "make-appcast":
            try makeAppcast(rest)
        case "release":
            try release(rest)
        case "render-preferences-previews":
            try renderPreferencesPreviews(rest)
        case "render-readme-assets":
            try renderReadmeAssets(rest)
        case "verify-appcast":
            try verifyAppcast(rest)
        case "help", "--help", "-h":
            printUsage()
        default:
            printUsage()
            throw ToolError("unknown command: \(command)")
        }
    }

    private func printUsage() {
        print(
            """
            Usage:
              pulsebar-tools changelog-to-html <version> [CHANGELOG.md]
              pulsebar-tools check-release-assets [tag]
              pulsebar-tools generate-release-notes <version> [output.md]
              pulsebar-tools make-appcast <PulseBar-version.zip> [feed-url]
              pulsebar-tools release
              pulsebar-tools render-readme-assets
              pulsebar-tools render-preferences-previews
              pulsebar-tools verify-appcast <appcast.xml> <version>

            Environment used by release/appcast:
              CODESIGN_IDENTITY, SPARKLE_PUBLIC_ED_KEY, SPARKLE_PRIVATE_KEY_FILE,
              NOTARY_PROFILE, APPCAST_URL, GITHUB_REPOSITORY
            """
        )
    }

    private func generateReleaseNotes(_ arguments: [String]) throws {
        guard arguments.count == 1 || arguments.count == 2 else {
            throw ToolError("Usage: pulsebar-tools generate-release-notes <version> [output.md]")
        }

        let notes = try releaseNotes(version: arguments[0], changelog: root.appendingPathComponent("CHANGELOG.md"))
        if arguments.count == 2 {
            try notes.write(to: URL(fileURLWithPath: arguments[1]), atomically: true, encoding: .utf8)
        } else {
            print(notes, terminator: "")
        }
    }

    private func renderReadmeAssets(_ arguments: [String]) throws {
        guard arguments.isEmpty else {
            throw ToolError("Usage: pulsebar-tools render-readme-assets")
        }

        let assetDirectory = root.appendingPathComponent("docs/assets")
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)

        let menuPreview = assetDirectory.appendingPathComponent("menu-preview.png")
        try ReadmeAssetRenderer.writeMenuPreview(to: menuPreview)
        print("Updated \(menuPreview.path)")
    }

    private func renderPreferencesPreviews(_ arguments: [String]) throws {
        guard arguments.isEmpty else { throw ToolError("Usage: pulsebar-tools render-preferences-previews") }
        let directory = root.appendingPathComponent(".build/preferences-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ReadmeAssetRenderer.writePreferencesPreviews(to: directory)
        print("Updated \(directory.path)")
    }

    private func changelogToHTML(_ arguments: [String]) throws {
        guard arguments.count == 1 || arguments.count == 2 else {
            throw ToolError("Usage: pulsebar-tools changelog-to-html <version> [CHANGELOG.md]")
        }

        let changelog = arguments.count == 2 ? URL(fileURLWithPath: arguments[1]) : root.appendingPathComponent("CHANGELOG.md")
        let notes = try releaseNotes(version: arguments[0], changelog: changelog)
        print(renderHTML(from: notes))
    }

    private func verifyAppcast(_ arguments: [String]) throws {
        let appcast: URL
        let version: String

        if arguments.count == 1 {
            appcast = root.appendingPathComponent("appcast.xml")
            version = arguments[0]
        } else if arguments.count == 2 {
            appcast = URL(fileURLWithPath: arguments[0])
            version = arguments[1]
        } else {
            throw ToolError("Usage: pulsebar-tools verify-appcast <appcast.xml> <version>")
        }

        guard FileManager.default.fileExists(atPath: appcast.path) else {
            throw ToolError("Appcast not found: \(appcast.path)")
        }

        let xml = try String(contentsOf: appcast, encoding: .utf8)
        guard xml.contains("<sparkle:shortVersionString>\(version)</sparkle:shortVersionString>") else {
            throw ToolError("Appcast does not contain short version \(version)")
        }
        guard xml.contains("PulseBar-\(version).zip") else {
            throw ToolError("Appcast does not reference PulseBar-\(version).zip")
        }
        guard xml.contains("sparkle:edSignature=") else {
            throw ToolError("Appcast entry does not contain a Sparkle edSignature")
        }

        print("Appcast contains PulseBar \(version) with a Sparkle signature.")
    }

    private func makeAppcast(_ arguments: [String]) throws {
        guard arguments.count == 1 || arguments.count == 2 else {
            throw ToolError("Usage: pulsebar-tools make-appcast <PulseBar-version.zip> [feed-url]")
        }

        let zip = URL(fileURLWithPath: arguments[0])
        let repository = environment["GITHUB_REPOSITORY"] ?? "amer8/pulsebar"
        let feedURL = arguments.count == 2 ? arguments[1] : "https://raw.githubusercontent.com/\(repository)/main/appcast.xml"
        let privateKeyFile = environment["SPARKLE_PRIVATE_KEY_FILE"] ?? ""

        guard !privateKeyFile.isEmpty else {
            throw ToolError("Set SPARKLE_PRIVATE_KEY_FILE to your Sparkle ed25519 private key file.")
        }
        guard FileManager.default.fileExists(atPath: privateKeyFile) else {
            throw ToolError("Sparkle private key file not found: \(privateKeyFile)")
        }
        guard FileManager.default.fileExists(atPath: zip.path) else {
            throw ToolError("Zip not found: \(zip.path)")
        }

        let generateAppcast = try resolveGenerateAppcast()
        let zipDirectory = zip.deletingLastPathComponent()
        let zipName = zip.lastPathComponent
        let zipBase = String(zipName.dropLast(".zip".count))
        let version = try inferReleaseVersion(zipName: zipName)
        let notesHTML = zipDirectory.appendingPathComponent("\(zipBase).html")
        try renderHTML(from: releaseNotes(version: version, changelog: root.appendingPathComponent("CHANGELOG.md")))
            .write(to: notesHTML, atomically: true, encoding: .utf8)

        let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pulsebar-appcast.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workDirectory)
            if environment["KEEP_SPARKLE_NOTES"] != "1" {
                try? FileManager.default.removeItem(at: notesHTML)
            }
        }

        let downloadURLPrefix =
            environment["SPARKLE_DOWNLOAD_URL_PREFIX"] ?? "https://github.com/\(repository)/releases/download/v\(version)/"
        try copyReplacing(root.appendingPathComponent("appcast.xml"), to: workDirectory.appendingPathComponent("appcast.xml"))
        try copyReplacing(zip, to: workDirectory.appendingPathComponent(zipName))
        try copyReplacing(notesHTML, to: workDirectory.appendingPathComponent("\(zipBase).html"))

        try Command.run(
            generateAppcast,
            [
                "--ed-key-file", privateKeyFile,
                "--download-url-prefix", downloadURLPrefix,
                "--embed-release-notes",
                "--link", feedURL,
                workDirectory.path,
            ],
            cwd: workDirectory
        )

        try copyReplacing(workDirectory.appendingPathComponent("appcast.xml"), to: root.appendingPathComponent("appcast.xml"))
        print("Updated \(root.appendingPathComponent("appcast.xml").path)")
    }

    private func checkReleaseAssets(_ arguments: [String]) throws {
        guard arguments.count <= 1 else {
            throw ToolError("Usage: pulsebar-tools check-release-assets [tag]")
        }

        try requireCommand("gh")
        let repository = try Command.capture("gh", ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], cwd: root)
            .trimmed()
        let tag = try arguments.first ?? Command.capture("git", ["describe", "--tags", "--abbrev=0"], cwd: root).trimmed()
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = try Command.capture(
            "gh",
            ["release", "view", tag, "--repo", repository, "--json", "assets", "--jq", ".assets[].name"],
            cwd: root
        )
        let assetNames = Set(assets.split(whereSeparator: \.isNewline).map(String.init))

        for asset in ["PulseBar-\(version).zip", "PulseBar-\(version).dSYM.zip", "PulseBar-\(version).dmg"] {
            guard assetNames.contains(asset) else {
                throw ToolError("\(asset) missing on release \(tag)")
            }
        }

        print("Release \(tag) has zip, dSYM zip, and DMG assets.")
    }

    private func release(_ arguments: [String]) throws {
        guard arguments.isEmpty else {
            throw ToolError("Usage: pulsebar-tools release")
        }

        let versionEnvironment = try loadEnvironmentFile(root.appendingPathComponent("version.env"))
        let marketingVersion = try required(versionEnvironment["MARKETING_VERSION"], name: "MARKETING_VERSION")
        let buildNumber = try required(versionEnvironment["BUILD_NUMBER"], name: "BUILD_NUMBER")
        let appName = "PulseBar"
        let tag = "v\(marketingVersion)"
        let repository = environment["GITHUB_REPOSITORY"] ?? "amer8/pulsebar"
        let appcastURL = environment["APPCAST_URL"] ?? "https://raw.githubusercontent.com/\(repository)/main/appcast.xml"
        let artifactDirectory = root.appendingPathComponent(".build/release/artifacts")
        let zip = artifactDirectory.appendingPathComponent("\(appName)-\(marketingVersion).zip")
        let dSYMZip = artifactDirectory.appendingPathComponent("\(appName)-\(marketingVersion).dSYM.zip")
        let dmg = artifactDirectory.appendingPathComponent("\(appName)-\(marketingVersion).dmg")
        let notaryProfile = environment["NOTARY_PROFILE"] ?? "pulsebar-notary"
        let codesignIdentity = try required(environment["CODESIGN_IDENTITY"], name: "CODESIGN_IDENTITY")
        let sparklePublicKey = try required(environment["SPARKLE_PUBLIC_ED_KEY"], name: "SPARKLE_PUBLIC_ED_KEY")
        let sparklePrivateKeyFile = try required(environment["SPARKLE_PRIVATE_KEY_FILE"], name: "SPARKLE_PRIVATE_KEY_FILE")

        try requireCommand("git")
        try requireCommand("gh")
        try requireCommand("make")
        try requireCommand("xcrun")
        try requireCommand("codesign")
        try requireCommand("spctl")
        try requireCleanWorktree()
        try validateSparklePrivateKey(sparklePrivateKeyFile)
        try ensureChangelogFinalized(version: marketingVersion)
        try ensureAppcastBuildIsMonotonic(buildNumber: buildNumber)

        try Command.run("make", ["check"], cwd: root)
        try Command.run(
            "make",
            [
                "release-artifacts",
                "APP_VERSION=\(marketingVersion)",
                "BUILD_NUMBER=\(buildNumber)",
                "CODESIGN_IDENTITY=\(codesignIdentity)",
                "NOTARY_PROFILE=\(notaryProfile)",
                "SPARKLE_PUBLIC_ED_KEY=\(sparklePublicKey)",
                "APPCAST_URL=\(appcastURL)",
            ],
            cwd: root
        )

        for file in [zip, dSYMZip, dmg] {
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw ToolError("missing release artifact: \(file.path)")
            }
        }

        let notesFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pulsebar-notes.\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: notesFile) }
        try releaseNotes(version: marketingVersion, changelog: root.appendingPathComponent("CHANGELOG.md"))
            .write(to: notesFile, atomically: true, encoding: .utf8)

        if try Command.capture("git", ["rev-parse", "-q", "--verify", "refs/tags/\(tag)"], cwd: root, allowFailure: true).isEmpty == false {
            throw ToolError("tag already exists: \(tag)")
        }

        try Command.run("git", ["tag", "-m", "\(appName) \(marketingVersion)", tag], cwd: root)
        try Command.run("git", ["push", "origin", tag], cwd: root)
        try Command.run(
            "gh",
            [
                "release", "create", tag,
                zip.path,
                dSYMZip.path,
                dmg.path,
                "--title", "\(appName) \(marketingVersion)",
                "--notes-file", notesFile.path,
            ],
            cwd: root
        )

        try makeAppcast([zip.path, appcastURL])
        try verifyAppcast([root.appendingPathComponent("appcast.xml").path, marketingVersion])

        try Command.run("git", ["add", root.appendingPathComponent("appcast.xml").path], cwd: root)
        try Command.run("git", ["commit", "-m", "docs: update appcast for \(marketingVersion)"], cwd: root)
        try Command.run("git", ["push", "origin", "main"], cwd: root)
        try checkReleaseAssets([tag])

        print("Release \(marketingVersion) complete.")
    }

    private func releaseNotes(version: String, changelog: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: changelog.path) else {
            throw ToolError("Missing CHANGELOG.md")
        }

        let lines = try String(contentsOf: changelog, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(
            String.init)
        var found = false
        var notes: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if found {
                    break
                }

                let title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if titleMatchesVersion(title, version: version) {
                    found = true
                    continue
                }
            }

            if found && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                notes.append(line)
            }
        }

        guard !notes.isEmpty else {
            throw ToolError("No changelog section found for \(version)")
        }

        return notes.joined(separator: "\n") + "\n"
    }

    private func renderHTML(from notes: String) -> String {
        var html = ""
        var inList = false

        for line in notes.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) where !line.isEmpty {
            if line.hasPrefix("- ") {
                if !inList {
                    html += "<ul>"
                    inList = true
                }
                html += "<li>\(htmlEscape(String(line.dropFirst(2))))</li>"
            } else if line.hasPrefix("### ") {
                if inList {
                    html += "</ul>"
                    inList = false
                }
                html += "<h3>\(htmlEscape(String(line.dropFirst(4))))</h3>"
            } else {
                if inList {
                    html += "</ul>"
                    inList = false
                }
                html += "<p>\(htmlEscape(line))</p>"
            }
        }

        if inList {
            html += "</ul>"
        }
        return html + "\n"
    }

    private func htmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func titleMatchesVersion(_ title: String, version: String) -> Bool {
        guard title.hasPrefix(version) else {
            return false
        }

        guard title.count > version.count else {
            return true
        }

        let next = title[title.index(title.startIndex, offsetBy: version.count)]
        return next.isWhitespace || next == "-"
    }

    private func inferReleaseVersion(zipName: String) throws -> String {
        if let explicit = environment["SPARKLE_RELEASE_VERSION"], !explicit.isEmpty {
            return explicit
        }

        guard zipName.hasPrefix("PulseBar-"), zipName.hasSuffix(".zip") else {
            throw ToolError("Could not infer version from \(zipName); set SPARKLE_RELEASE_VERSION.")
        }

        return String(zipName.dropFirst("PulseBar-".count).dropLast(".zip".count))
    }

    private func resolveGenerateAppcast() throws -> String {
        if let override = environment["GENERATE_APPCAST"], !override.isEmpty {
            return override
        }

        if let path = try? Command.capture("/usr/bin/which", ["generate_appcast"], cwd: root, allowFailure: true).trimmed(), !path.isEmpty {
            return path
        }

        let bundled = root.appendingPathComponent(".build/artifacts/sparkle/Sparkle/bin/generate_appcast")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }

        throw ToolError("generate_appcast was not found. Run swift package resolve or install Sparkle tools before releasing.")
    }

    private func requireCommand(_ name: String) throws {
        let path = try Command.capture("/usr/bin/which", [name], cwd: root, allowFailure: true).trimmed()
        guard !path.isEmpty else {
            throw ToolError("\(name) is required")
        }
    }

    private func requireCleanWorktree() throws {
        let status = try Command.capture("git", ["status", "--porcelain"], cwd: root)
        guard status.isEmpty else {
            let shortStatus = try Command.capture("git", ["status", "--short"], cwd: root)
            print(shortStatus, terminator: "")
            throw ToolError("release requires a clean worktree")
        }
    }

    private func validateSparklePrivateKey(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolError("Sparkle private key file not found: \(path)")
        }

        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard lines.count == 1 else {
            throw ToolError("Sparkle private key file must contain exactly one non-comment key line")
        }
    }

    private func ensureChangelogFinalized(version: String) throws {
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        guard let firstSection = changelog.split(separator: "\n").first(where: { $0.hasPrefix("## ") }) else {
            throw ToolError("CHANGELOG.md has no release section")
        }

        let title = String(firstSection.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        guard !title.contains("Unreleased") else {
            throw ToolError("top changelog section must be finalized, not Unreleased")
        }
        guard title.hasPrefix(version) else {
            throw ToolError("top changelog section must start with \(version)")
        }
    }

    private func ensureAppcastBuildIsMonotonic(buildNumber: String) throws {
        guard let currentBuild = Int(buildNumber) else {
            throw ToolError("BUILD_NUMBER=\(buildNumber) must be numeric")
        }

        let appcast = root.appendingPathComponent("appcast.xml")
        guard FileManager.default.fileExists(atPath: appcast.path) else {
            return
        }

        let xml = try String(contentsOf: appcast, encoding: .utf8)
        let builds = appcastBuildNumbers(xml)
        if let latest = builds.max(), currentBuild <= latest {
            throw ToolError("BUILD_NUMBER=\(buildNumber) must be greater than latest appcast build \(latest)")
        }
    }

    private func appcastBuildNumbers(_ xml: String) -> [Int] {
        let marker = "<sparkle:version>"
        var numbers: [Int] = []
        var searchStart = xml.startIndex

        while let markerRange = xml.range(of: marker, range: searchStart..<xml.endIndex) {
            var index = markerRange.upperBound
            var digits = ""
            while index < xml.endIndex, xml[index].isNumber {
                digits.append(xml[index])
                index = xml.index(after: index)
            }
            if let number = Int(digits) {
                numbers.append(number)
            }
            searchStart = index
        }

        return numbers
    }

    private func required(_ value: String?, name: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw ToolError("\(name) is required")
        }
        return value
    }

    private func loadEnvironmentFile(_ url: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }

        var result: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                result[String(parts[0])] = unquoted(String(parts[1]))
            }
        }
        return result
    }

    private func unquoted(_ value: String) -> String {
        if value.count >= 2,
            let first = value.first,
            let last = value.last,
            (first == "\"" && last == "\"") || (first == "'" && last == "'")
        {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func copyReplacing(_ source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

private enum ProjectRoot {
    static func find() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["PULSEBAR_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            let package = candidate.appendingPathComponent("Package.swift")
            let sources = candidate.appendingPathComponent("Sources")
            if FileManager.default.fileExists(atPath: package.path) && FileManager.default.fileExists(atPath: sources.path) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                throw ToolError("could not find project root")
            }
            candidate = parent
        }
    }
}

private enum Command {
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil, environment: [String: String]? = nil) throws {
        try execute(executable, arguments, cwd: cwd, environment: environment, captureOutput: false, allowFailure: false)
    }

    static func capture(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        allowFailure: Bool = false
    ) throws -> String {
        try execute(executable, arguments, cwd: cwd, environment: environment, captureOutput: true, allowFailure: allowFailure)
    }

    @discardableResult
    private static func execute(
        _ executable: String,
        _ arguments: [String],
        cwd: URL?,
        environment: [String: String]?,
        captureOutput: Bool,
        allowFailure: Bool
    ) throws -> String {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.currentDirectoryURL = cwd
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        if captureOutput {
            process.standardOutput = stdout
            process.standardError = stderr
        }

        try process.run()
        process.waitUntilExit()

        if captureOutput {
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0 && !allowFailure {
                if !errorOutput.isEmpty {
                    FileHandle.standardError.writeLine(errorOutput.trimmingCharacters(in: .newlines))
                }
                throw ToolError(commandFailureMessage(executable: executable, arguments: arguments, status: process.terminationStatus))
            }
            return process.terminationStatus == 0 ? output : ""
        }

        if process.terminationStatus != 0 && !allowFailure {
            throw ToolError(commandFailureMessage(executable: executable, arguments: arguments, status: process.terminationStatus))
        }
        return ""
    }

    private static func commandFailureMessage(executable: String, arguments: [String], status: Int32) -> String {
        "command failed (\(status)): \(([executable] + arguments).joined(separator: " "))"
    }
}

private struct ToolError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

extension FileHandle {
    fileprivate func writeLine(_ string: String) {
        if let data = (string + "\n").data(using: .utf8) {
            write(data)
        }
    }
}

extension String {
    fileprivate func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
private enum ReadmeAssetRenderer {
    static func writeMenuPreview(to url: URL) throws {
        let appIcon = NSImage(contentsOf: url.deletingLastPathComponent().appendingPathComponent("app-icon.png"))
        let renderer = ImageRenderer(
            content: ReadmeMenuPreview(appIcon: appIcon).environment(\.colorScheme, .light).environment(
                \.locale, Locale(identifier: "en_US")
            ).environment(\.timeZone, TimeZone(secondsFromGMT: 0)!))
        renderer.scale = 2
        renderer.colorMode = .nonLinear

        guard let image = renderer.nsImage else {
            throw ToolError("failed to render README menu preview")
        }

        try image.writePNG(to: url)
    }

    static func writePreferencesPreviews(to directory: URL) throws {
        for scheme: ColorScheme in [.light, .dark] {
            for sample in [PreferencesSample.signedIn, .signedOut, .invalidPort] {
                let name = "\(sample.rawValue)-\(scheme == .light ? "light" : "dark").png"
                let height: CGFloat = sample == .signedIn ? 420 : (sample == .signedOut ? 480 : 520)
                let image = try nativeImage(PreferencesSampleView(sample: sample), size: NSSize(width: 560, height: height), scheme: scheme)
                try image.writePNG(to: directory.appendingPathComponent(name))
            }
        }
    }

    private static func nativeImage<Content: View>(_ content: Content, size: NSSize, scheme: ColorScheme) throws -> NSImage {
        // Native fields and buttons need AppKit drawing; ImageRenderer omits platform-backed controls.
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        let view = NSHostingView(
            rootView: content.environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw ToolError("failed to render preferences preview") }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        window.close()
        return image
    }
}

private enum PreferencesSample: String {
    case signedIn = "signed-in"
    case signedOut = "signed-out"
    case invalidPort = "invalid-port"
}

private struct PreferencesSampleView: View {
    let sample: PreferencesSample
    private var state: DashboardPreferencesState {
        var state = DashboardPreferencesState(endpointAddress: "127.0.0.1:11000", accountName: sample == .signedIn ? "demo" : nil)
        state.connectionTitle = sample == .signedIn ? "Connected" : "Signed out"
        state.connectionTone = sample == .signedIn ? .success : .neutral
        state.canSignIn = true
        if sample == .invalidPort {
            state.canApplyPort = true
            state.canTestConnection = false
            state.feedback = PreferencesFeedback("Port must be between 1 and 65535.", tone: .error)
        }
        return state
    }
    var body: some View {
        DashboardPreferencesContent(
            port: .constant(sample == .invalidPort ? "70000" : "11000"), username: .constant("demo"), password: .constant("sample"),
            showDiagnostics: .constant(false), state: state, actions: DashboardPreferencesActions()
        )
    }
}

// Rendered UI preview with fixed sample data; it does not contact services or change preferences.
private struct ReadmeMenuPreview: View {
    private let cardWidth: CGFloat = 720
    private let cardHeight: CGFloat = 400
    private let safeInset: CGFloat = 40

    let appIcon: NSImage?

    var body: some View {
        ZStack(alignment: .top) {
            backgroundView

            VStack(spacing: 0) {
                menuBar

                HStack(alignment: .top, spacing: 26) {
                    titleBlock
                        .padding(.top, 34)

                    menuCard
                        .frame(width: 330)
                        .padding(.top, 3)
                }
                .padding(.horizontal, safeInset)
            }
            .padding(.top, 32)
        }
        .frame(width: cardWidth, height: cardHeight)
    }

    private var titleBlock: some View {
        HStack(alignment: .center, spacing: 14) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 58, height: 58)
                    .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("PulseBar")
                    .font(.system(size: 23, weight: .semibold))
                Text("Live DGX Dashboard telemetry in the macOS menu bar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 266, alignment: .leading)
    }

    private var backgroundView: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 1.0, green: 0.13, blue: 0.07), location: 0.0),
                    .init(color: Color(red: 1.0, green: 0.49, blue: 0.13), location: 0.34),
                    .init(color: Color(red: 0.96, green: 0.19, blue: 0.62), location: 0.74),
                    .init(color: Color(red: 0.64, green: 0.0, blue: 0.82), location: 1.0),
                ],
                startPoint: .topLeading,
                endPoint: UnitPoint(x: 640 / cardWidth, y: 320 / cardHeight)
            )

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.95, blue: 0.37).opacity(0.72),
                            Color(red: 1.0, green: 0.34, blue: 0.58).opacity(0.32),
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .frame(width: 210, height: 560)
                .rotationEffect(.degrees(-20))
                .offset(x: -110 - (cardWidth - 640) / 2, y: 140 - (cardHeight - 320) / 2)
                .blur(radius: 34)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.3),
                            Color(red: 1.0, green: 0.55, blue: 0.64).opacity(0.16),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 300, height: 230)
                .rotationEffect(.degrees(11))
                .offset(x: 190 - (cardWidth - 640) / 2, y: -24 - (cardHeight - 320) / 2)
                .blur(radius: 26)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.2),
                    Color.clear,
                    Color.black.opacity(0.08),
                ],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 320 / cardHeight)
            )
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipped()
    }

    private var menuBar: some View {
        HStack(spacing: 18) {
            Text("PulseBar")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                Text("56%")
                Image(systemName: "cpu.fill")
                Text("37%")
            }
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.08), in: Capsule())

            Text("9:41")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, safeInset)
        .frame(height: 32)
        .background(.white.opacity(0.18))
    }

    private var menuCard: some View {
        VStack(spacing: 0) {
            previewRow(symbol: "network", title: "Connected")
            plainRow("Last sample: 9:41:00 AM", secondary: true)
            plainRow("Reconnect")
            divider
            previewRow(symbol: "memorychip", title: "RAM: 56% (71.68 / 128 GB)")
            previewRow(symbol: "cpu.fill", title: "GPU: 37%")
            divider
            previewRow(symbol: "gearshape", title: "Preferences…", shortcut: "⌘,")
            previewRow(symbol: "safari", title: "Open Dashboard")
            divider
            previewRow(symbol: "power", title: "Quit", shortcut: "⌘Q")
        }
        .frame(width: 330)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.65), lineWidth: 1) }
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 12)
    }

    private func plainRow(_ title: String, secondary: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(secondary ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 27)
    }

    private func previewRow(symbol: String, title: String, shortcut: String? = nil) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: symbol)
                    .frame(width: 18)
            }

            Spacer(minLength: 12)

            if let shortcut {
                Text(shortcut)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 27)
    }

    private var divider: some View {
        Rectangle()
            .fill(.primary.opacity(0.13))
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}

extension NSImage {
    fileprivate func writePNG(to url: URL) throws {
        // Eight-bit sRGB preserves crisp Retina text without oversized 16-bit PNGs.
        guard let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation),
            let image = bitmap.cgImage,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ToolError("failed to create PNG bitmap: \(url.path)") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let output = context.makeImage(),
            let data = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
        else { throw ToolError("failed to encode PNG: \(url.path)") }
        try data.write(to: url, options: .atomic)
    }
}
