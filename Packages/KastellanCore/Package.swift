// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KastellanCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KastellanCore", targets: ["KastellanCore"]),
    ],
    dependencies: [
        // Nur außerhalb von Apple-Plattformen; dort ersetzt swift-crypto CryptoKit mit derselben API.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
    ],
    targets: [
        .target(name: "KastellanCore", dependencies: [
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows, .android])),
        ]),
        .testTarget(
            name: "KastellanCoreTests",
            dependencies: ["KastellanCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
