// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BodyPoseTracker",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BodyPoseTrackerCore", targets: ["BodyPoseTrackerCore"]),
        .executable(name: "BodyPoseTrackerMenubar", targets: ["BodyPoseTrackerMenubar"])
    ],
    targets: [
        .target(name: "BodyPoseTrackerCore"),
        .executableTarget(
            name: "BodyPoseTrackerMenubar",
            dependencies: ["BodyPoseTrackerCore"]
        ),
        .testTarget(
            name: "BodyPoseTrackerCoreTests",
            dependencies: ["BodyPoseTrackerCore"]
        )
    ]
)
