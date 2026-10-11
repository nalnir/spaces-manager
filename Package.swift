// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SpacesManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpacesManager", targets: ["SpacesManager"]),
    ],
    targets: [
        .executableTarget(
            name: "SpacesManager",
            resources: [.process("Resources")]
        ),
    ]
)