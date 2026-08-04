// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoBrightness",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "AutoBrightnessCore"),
        .executableTarget(
            name: "AutoBrightnessApp",
            dependencies: ["AutoBrightnessCore"]
        ),
        .executableTarget(
            name: "ALSProbe",
            dependencies: ["AutoBrightnessCore"]
        ),
        .testTarget(
            name: "AutoBrightnessCoreTests",
            dependencies: ["AutoBrightnessCore"]
        ),
    ]
)
