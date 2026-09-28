// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KastellanCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KastellanCore", targets: ["KastellanCore"]),
    ],
    targets: [
        .target(name: "KastellanCore"),
        .testTarget(
            name: "KastellanCoreTests",
            dependencies: ["KastellanCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
