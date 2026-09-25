// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TouchBridgeProbe",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "TouchBridgeProbe",
            dependencies: [],
            path: "Sources/TouchBridgeProbe",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics")
            ]
        )
    ]
)
