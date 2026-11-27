// swift-tools-version: 6.0
import Foundation
import PackageDescription

let minimumMacOSVersion = "13.0"

// SwiftPM's Xcode build system can otherwise record the deployment target as the linked SDK,
// causing macOS to use compatibility appearances even when building with a newer SDK.
let sdkQuery = Process()
sdkQuery.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
let selectedSDK = ProcessInfo.processInfo.environment["SDKROOT"].flatMap { $0.isEmpty ? nil : $0 } ?? "macosx"
sdkQuery.arguments = ["--sdk", selectedSDK, "--show-sdk-version"]
let sdkOutput = Pipe()
sdkQuery.standardOutput = sdkOutput
try sdkQuery.run()
let sdkData = sdkOutput.fileHandleForReading.readDataToEndOfFile()
sdkQuery.waitUntilExit()
let macOSSDKVersion = String(decoding: sdkData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
guard sdkQuery.terminationStatus == 0, !macOSSDKVersion.isEmpty else {
    fatalError("Could not determine the selected macOS SDK version with xcrun")
}

let package = Package(
    name: "PulseBar",
    platforms: [
        .macOS(minimumMacOSVersion)
    ],
    products: [
        .executable(
            name: "PulseBar",
            targets: ["PulseBarApp"]
        ),
        .executable(
            name: "pulsebar-tools",
            targets: ["PulseBarTools"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "PulseBarApp",
            dependencies: [
                "LoginKeychain",
                "PulseBarUI",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/PulseBarApp",
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                        "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                        "-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", minimumMacOSVersion,
                        "-Xlinker", macOSSDKVersion,
                    ], .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "PulseBarTools",
            dependencies: ["PulseBarUI"],
            path: "Sources/PulseBarTools"
        ),
        .target(name: "PulseBarUI", path: "Sources/PulseBarUI"),
        .target(name: "LoginKeychain"),
        .testTarget(
            name: "PulseBarAppTests",
            dependencies: ["PulseBarApp", "PulseBarUI", "PulseBarTools"],
            path: "Tests/PulseBarAppTests"
        ),
    ]
)
