// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacshotStudio",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ainame/Swift-WebP.git", exact: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "MacshotStudio",
            dependencies: [.product(name: "WebP", package: "Swift-WebP")],
            path: "Sources/MacshotStudio",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .define("OFFLINE"),
                .define("MACSHOT_STUDIO"),
            ]
        ),
    ]
)
