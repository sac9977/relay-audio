// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
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
        .executableTarget(
            name: "RelaySatelliteIOS",
            dependencies: ["SatelliteKit"],
            path: "Sources/RelaySatelliteIOS"
        ),
        .target(
            name: "SatelliteKit",
            path: "Sources/SatelliteKit"
        ),
    ]
)
