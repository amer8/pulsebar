import AppKit
import Darwin
import Foundation
import PulseBarUI
import SwiftUI

@main
@MainActor
enum PulseBarTools {
    static func main() async {
        do {
            try await Tool().run(Array(CommandLine.arguments.dropFirst()))
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

    func run(_ arguments: [String]) async throws {
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
        case "render-history-previews":
            try renderHistoryPreviews(rest)
        case "render-preferences-previews":
            try await renderPreferencesPreviews(rest)
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
              pulsebar-tools render-history-previews
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

    private func renderHistoryPreviews(_ arguments: [String]) throws {
        guard arguments.isEmpty else { throw ToolError("Usage: pulsebar-tools render-history-previews") }
        let directory = root.appendingPathComponent(".build/history-panel-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ReadmeAssetRenderer.writeHistoryPreviews(to: directory)
        print("Updated \(directory.path)")
    }

    private func renderPreferencesPreviews(_ arguments: [String]) async throws {
        guard arguments.isEmpty else { throw ToolError("Usage: pulsebar-tools render-preferences-previews") }
        let directory = root.appendingPathComponent(".build/preferences-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await ReadmeAssetRenderer.writePreferencesPreviews(to: directory)
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
        let reference = Date(timeIntervalSince1970: 1_700_041_260)
        let state = historySample(at: reference)
        let panel = try nativeImage(
            TelemetryHistoryPanel(state: state, now: reference, historySeconds: .constant(300), actions: TelemetryPanelActions()),
            size: TelemetryHistoryPanel.preferredSize(for: state), scheme: .light)
        let renderer = ImageRenderer(
            content: ReadmeMenuPreview(appIcon: appIcon, panel: panel)
                .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!))
        renderer.scale = 2
        renderer.colorMode = .nonLinear
        guard let image = renderer.nsImage else { throw ToolError("failed to render README preview") }
        try image.writePNG(to: url)
    }

    private static func historySample(at reference: Date) -> TelemetryPanelState {
        var state = TelemetryPanelState(connectionTitle: "Connected")
        state.isLive = true
        state.canReconnect = true
        state.lastSampleAt = reference
        state.memoryPercent = 56
        state.gpuPercent = 37
        state.usedMemoryGiB = 71.68
        state.totalMemoryGiB = 128
        state.freeMemoryGiB = 56.32
        let values: [(Double, Double)] = [
            (41, 17), (44, 34), (46, 61), (45, 48), (49, 72), (52, 67), (58, 84), (61, 59), (59, 68), (57, 49), (56, 37),
        ]
        state.points = values.enumerated().map { index, value in
            TelemetryChartPoint(
                timestamp: reference.addingTimeInterval(Double(index - 10) * 30), memoryPercent: value.0, gpuPercent: value.1)
        }
        return state
    }

    static func writeHistoryPreviews(to directory: URL) throws {
        let reference = Date(timeIntervalSince1970: 1_700_041_260)
        for scheme: ColorScheme in [.light, .dark] {
            for name in ["live", "low-use", "full-scale", "reconnecting", "signed-out"] {
                var state = historySample(at: reference)
                switch name {
                case "low-use", "full-scale":
                    state.memoryPercent = 2
                    state.gpuPercent = 0
                    state.usedMemoryGiB = 2.58
                    state.totalMemoryGiB = 122
                    state.freeMemoryGiB = 119.11
                    state.systemUpdateAvailable = true
                    state.points = state.points.map {
                        TelemetryChartPoint(timestamp: $0.timestamp, memoryPercent: 2, gpuPercent: 0)
                    }
                case "reconnecting":
                    state.connectionTitle = "Reconnecting…"
                    state.isLive = false
                    state.needsAttention = true
                    state.lastSampleAt = reference.addingTimeInterval(-35)
                    state.memoryPercent = nil
                    state.gpuPercent = nil
                    state.usedMemoryGiB = nil
                    state.totalMemoryGiB = nil
                    state.freeMemoryGiB = nil
                    state.note = "Waiting for the dashboard. Your recent history is preserved."
                case "signed-out":
                    state = TelemetryPanelState(connectionTitle: "Signed out")
                    state.needsSignIn = true
                default: break
                }
                let panel = try nativeImage(
                    TelemetryHistoryPanel(
                        state: state, now: reference, historySeconds: .constant(300), actions: TelemetryPanelActions(),
                        automaticScale: name != "full-scale"),
                    size: TelemetryHistoryPanel.preferredSize(for: state), scheme: scheme)
                try panel.writePNG(to: directory.appendingPathComponent("panel-\(name)-\(scheme == .light ? "light" : "dark").png"))
            }
        }
    }

    static func writePreferencesPreviews(to directory: URL) async throws {
        var records: [PreferencesPreviewRecord] = []
        for scheme: ColorScheme in [.light, .dark] {
            for sample in [PreferencesSample.signedIn, .signedOut, .invalidPort] {
                let name = "\(sample.rawValue)-\(scheme == .light ? "light" : "dark").png"
                records.append(
                    try await adaptivePreview(
                        sample: sample, scheme: scheme, visibleFrame: NSRect(x: 0, y: 24, width: 1440, height: 900),
                        name: name, directory: directory))
            }
        }
        records.append(
            try await adaptivePreview(
                sample: .signedIn, scheme: .dark, visibleFrame: NSRect(x: 0, y: 24, width: 1440, height: 900),
                name: "large-text-dark.png", directory: directory, bodyFontSize: 20))
        records.append(
            try await adaptivePreview(
                sample: .signedOut, scheme: .dark, visibleFrame: NSRect(x: 0, y: 24, width: 800, height: 540),
                name: "small-screen-dark.png", directory: directory))
        records.append(
            try await adaptivePreview(
                sample: .signedIn, scheme: .dark, visibleFrame: NSRect(x: 0, y: 24, width: 360, height: 900),
                name: "narrow-screen-dark.png", directory: directory))
        guard let regular = records.first(where: { $0.name == "signed-in-dark.png" }),
            let larger = records.first(where: { $0.name == "large-text-dark.png" }), larger.contentSize.height > regular.contentSize.height
        else { throw ToolError("larger text did not exercise a taller layout") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: directory.appendingPathComponent("layout.json"))
    }

    private static func adaptivePreview(
        sample: PreferencesSample, scheme: ColorScheme, visibleFrame: NSRect, name: String, directory: URL,
        bodyFontSize: CGFloat? = nil
    ) async throws -> PreferencesPreviewRecord {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 660), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let sizing = PreferencesWindowSizing(window: window, visibleFrameProvider: { visibleFrame })
        let view = NSHostingView(
            rootView: PreferencesSampleView(
                sample: sample, onContentSizeChange: { [weak sizing] size in sizing?.contentSizeDidChange(size) }
            )
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en_US"))
            .font(bodyFontSize.map { .system(size: $0) }).controlSize(bodyFontSize == nil ? .regular : .large))
        view.sizingOptions = []
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = view
        var previousFrame = NSRect.zero
        var stablePasses = 0
        for _ in 0..<30 {
            view.layoutSubtreeIfNeeded()
            _ = try capture(view)
            try await Task.sleep(for: .milliseconds(10))
            stablePasses = window.frame == previousFrame && sizing.measuredContentSize != .zero ? stablePasses + 1 : 0
            if stablePasses >= 2 { break }
            previousFrame = window.frame
        }
        guard sizing.measuredContentSize != .zero, stablePasses >= 2 else {
            try capture(view).writePNG(to: directory.appendingPathComponent("unsettled-\(name)"))
            throw ToolError("preferences sizing did not settle: \(name), measured \(sizing.measuredContentSize), window \(window.frame)")
        }
        let record = PreferencesPreviewRecord(
            name: name, frame: window.frame, visibleFrame: visibleFrame, contentSize: sizing.measuredContentSize,
            viewport: view.bounds.size, needsScrolling: sizing.measuredContentSize.height > view.bounds.height + 1)
        guard visibleFrame.contains(window.frame) else { throw ToolError("preferences exceeded the display: \(name)") }
        guard record.contentSize.width <= record.viewport.width + 1 else { throw ToolError("preferences clipped horizontally: \(name)") }
        if name != "small-screen-dark.png", record.needsScrolling { throw ToolError("preferences unnecessarily scroll: \(name)") }
        try capture(view).writePNG(to: directory.appendingPathComponent(name))
        return record
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
        defer { window.close() }
        return try capture(view)
    }

    private static func capture(_ view: NSView) throws -> NSImage {
        let size = view.bounds.size
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw ToolError("failed to render preferences preview") }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}

private struct PreferencesPreviewRecord: Encodable {
    let name: String
    let frame: NSRect
    let visibleFrame: NSRect
    let contentSize: NSSize
    let viewport: NSSize
    let needsScrolling: Bool
}

private enum PreferencesSample: String {
    case signedIn = "signed-in"
    case signedOut = "signed-out"
    case invalidPort = "invalid-port"
}

private struct PreferencesSampleView: View {
    let sample: PreferencesSample
    var onContentSizeChange: @MainActor @Sendable (CGSize) -> Void = { _ in }
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
            state: state, actions: DashboardPreferencesActions(), additionalCardsFirst: true,
            onContentSizeChange: onContentSizeChange
        ) {
            WelcomePreferencesContent(isVisible: true, endpointAddress: "127.0.0.1:11000", dismiss: {})
            StartupPreferencesContent(isEnabled: .constant(true), status: "Enabled", openSettings: {})
            MenuBarPreferencesContent(display: .constant(.both))
        }
    }
}

// Rendered UI preview with fixed sample data; it does not contact services or change preferences.
private struct ReadmeMenuPreview: View {
    private let cardWidth: CGFloat = 830
    private let cardHeight: CGFloat = 610
    private let safeInset: CGFloat = 40

    let appIcon: NSImage?
    let panel: NSImage

    var body: some View {
        ZStack(alignment: .top) {
            backgroundView

            VStack(spacing: 0) {
                menuBar

                HStack(alignment: .top, spacing: 26) {
                    titleBlock
                        .padding(.top, 34)

                    menuCard
                        .frame(width: 440, alignment: .leading)
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
        Image(nsImage: panel)
            .resizable().frame(width: panel.size.width, height: panel.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.4), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 12)
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
