// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Lagoon",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LagoonKit", targets: ["LagoonKit"]),
        .executable(name: "LagoonServer", targets: ["LagoonServer"]),
        .executable(name: "Lagoon", targets: ["Lagoon"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.6.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.9.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.27.0"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.0")
    ],
    targets: [
        .target(name: "LagoonKit", dependencies: [
            .product(name: "PostgresNIO", package: "postgres-nio"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Logging", package: "swift-log")
        ], exclude: ["Migrations"]),
        .target(name: "LagoonAI", dependencies: [
            "LagoonKit",
            .product(name: "Logging", package: "swift-log")
        ], exclude: ["README.md"]),
        .executableTarget(name: "LagoonServer", dependencies: [
            "LagoonKit",
            "LagoonAI",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "PostgresNIO", package: "postgres-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .executableTarget(name: "Lagoon", dependencies: ["LagoonKit"]),
        .testTarget(name: "LagoonKitTests", dependencies: ["LagoonKit"]),
        .testTarget(name: "LagoonServerTests", dependencies: [
            "LagoonServer",
            "LagoonKit",
            .product(name: "HummingbirdTesting", package: "hummingbird")
        ]),
        .testTarget(name: "LagoonTests", dependencies: ["Lagoon"]),
        .testTarget(name: "LagoonAITests", dependencies: ["LagoonAI", "LagoonKit"])
    ]
)