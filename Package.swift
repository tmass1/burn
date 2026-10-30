// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Burn",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        // In-app updates: the appcast, the EdDSA check on every download, and the Software Update window.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Burn",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Burn",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            // Sparkle.framework ships inside the bundle, in Contents/Frameworks.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "BurnTests",
            dependencies: ["Burn"],
            path: "Tests/BurnTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
