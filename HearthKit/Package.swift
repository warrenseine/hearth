// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HearthKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "HearthKit", targets: ["HearthKit"])
    ],
    targets: [
        .target(
            name: "HearthKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HearthKitTests",
            dependencies: ["HearthKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
