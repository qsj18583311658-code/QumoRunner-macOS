// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QumoRunnerMacOS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RunnerCore", targets: ["RunnerCore"]),
        .executable(name: "libtv-contract-check", targets: ["LibTVContractCheck"]),
    ],
    targets: [
        .executableTarget(name: "LibTVContractCheck", dependencies: ["RunnerCore"]),
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
