// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PulseBar",
    platforms: [
        .macOS(.v13)
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
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1")
    ],
    targets: [
        .executableTarget(
            name: "PulseBarApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/PulseBarApp",
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                        "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                    ], .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "PulseBarTools",
            path: "Sources/PulseBarTools"
        ),
        .testTarget(
            name: "PulseBarAppTests",
            dependencies: ["PulseBarApp"],
            path: "Tests/PulseBarAppTests"
        ),
    ]
)
