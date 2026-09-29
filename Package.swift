// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Lagoon",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LagoonKit", targets: ["LagoonKit"]),
        .library(name: "LagoonServer", targets: ["LagoonServer"]),
        .executable(name: "LagoonServerCLI", targets: ["LagoonServerCLI"]),
        .executable(name: "Lagoon", targets: ["Lagoon"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.6.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.11.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.9.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.27.0"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.0")
    ],
    targets: [
        .target(name: "LagoonKit", dependencies: [
            .product(name: "GRDB", package: "grdb.swift"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Logging", package: "swift-log")
        ]),
        .target(name: "LagoonAI", dependencies: [
            "LagoonKit",
            .product(name: "Logging", package: "swift-log")
        ], exclude: ["README.md"]),
        .target(name: "LagoonServer", dependencies: [
            "LagoonKit",
            "LagoonAI",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "GRDB", package: "grdb.swift"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .executableTarget(name: "Lagoon", dependencies: ["LagoonServer", "LagoonKit"]),
        .executableTarget(name: "LagoonServerCLI", dependencies: ["LagoonServer", "LagoonKit"]),
        .testTarget(name: "LagoonKitTests", dependencies: ["LagoonKit"]),
        .testTarget(name: "LagoonServerTests", dependencies: [
            "LagoonServer",
            "LagoonKit",
            .product(name: "HummingbirdTesting", package: "hummingbird")
        ], exclude: ["Fixtures"]),
        .testTarget(name: "LagoonTests", dependencies: ["Lagoon"]),
        .testTarget(name: "LagoonAITests", dependencies: ["LagoonAI", "LagoonKit"])
    ]
)