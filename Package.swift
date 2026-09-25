// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Relay",
            dependencies: ["SatelliteKit"],
            path: "Sources/Relay"
        ),
        .executableTarget(
            name: "RelaySatellite",
            dependencies: ["SatelliteKit"],
            path: "Sources/RelaySatellite"
        ),
        .target(
            name: "SatelliteKit",
            path: "Sources/SatelliteKit"
        ),
    ]
)
