// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QumoRunnerMacOS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RunnerCore", targets: ["RunnerCore"]),
    ],
    targets: [
        .target(
            name: "RunnerCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "RunnerCoreTests",
            dependencies: ["RunnerCore"],
            resources: [.copy("Resources")]
        ),
    ]
)
