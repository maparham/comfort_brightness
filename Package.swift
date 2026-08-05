// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoBrightness",
    platforms: [.macOS(.v15)],
    products: [
        // Exposed so the Xcode app target can depend on the engine. The package
        // itself keeps building the executables for `swift build` / `swift test`.
        .library(name: "AutoBrightnessCore", targets: ["AutoBrightnessCore"]),
    ],
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
