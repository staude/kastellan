// swift-tools-version: 6.0
// Kopie des MCP Swift SDK 0.12.1 (https://github.com/modelcontextprotocol/swift-sdk), nur das Ziel MCP.
// Einzige Änderung: HTTPClientTransport fragt `canImport(EventSource)` statt `os(Linux)` ab, damit das
// SDK unter Windows baut (EventSource ist dort nicht eingebunden). Kastellan nutzt diese Kopie nur
// beim Bauen unter Windows, siehe Package.swift im Repo-Root. Lizenz: LICENSE (MIT/Apache-2.0).
import PackageDescription

let package = Package(
    name: "mcp-swift-sdk",
    platforms: [.macOS("13.0")],
    products: [.library(name: "MCP", targets: ["MCP"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-system.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MCP",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
