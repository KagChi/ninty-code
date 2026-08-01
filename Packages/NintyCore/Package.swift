// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NintyCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NintyCore", targets: ["NintyCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0")
    ],
    targets: [
        .target(
            name: "NintyCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            resources: [.copy("Resources/models.json")]
        ),
        .testTarget(
            name: "NintyCoreTests",
            dependencies: ["NintyCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
