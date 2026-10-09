// swift-tools-version: 6.0
// Kommandozeilen-Programme von Kastellan für macOS, Linux und Windows:
//   kastellan      Terminal-Oberfläche (Verbindungen, Rechte, MCP-Clients, Freigaben, Protokoll)
//   kastellan-mcp  MCP-Server über stdio
// Die macOS-App entsteht weiter aus project.yml (XcodeGen) und nutzt dieselben Quellen für kastellan-mcp.
import PackageDescription

let package = Package(
    name: "Kastellan",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kastellan", targets: ["kastellan"]),
        .executable(name: "kastellan-mcp", targets: ["kastellan-mcp"]),
    ],
    dependencies: [
        .package(path: "Packages/KastellanCore"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "kastellan",
            dependencies: [.product(name: "KastellanCore", package: "KastellanCore")],
            path: "Sources/kastellan"
        ),
        .executableTarget(
            name: "kastellan-mcp",
            dependencies: [
                .product(name: "KastellanCore", package: "KastellanCore"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "kastellan-mcp",
            exclude: ["kastellan-mcp.entitlements"]
        ),
    ]
)
