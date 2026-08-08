// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Atelier",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Atelier", targets: ["Atelier"])
    ],
    targets: [
        .target(name: "Atelier"),
        .testTarget(
            name: "AtelierTests",
            dependencies: ["Atelier"]
        ),
        .executableTarget(
            name: "AtelierDemo",
            dependencies: ["Atelier"],
            path: "Demo"
        ),
    ]
)
