// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PhotoBench",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PhotoCore", targets: ["PhotoCore"]),
        .library(name: "NihoCameraCutout", targets: ["NihoCameraCutout"]),
        .library(name: "PhotoBenchAppSupport", targets: ["PhotoBenchAppSupport"]),
        .library(
            name: "PhotoBenchCalibrationSupport",
            targets: ["PhotoBenchCalibrationSupport"]
        ),
        .executable(name: "PhotoBench", targets: ["PhotoBenchApp"]),
        .executable(name: "PhotoBenchCalibration", targets: ["PhotoBenchCalibration"]),
        .executable(
            name: "PhotoBenchWhiteBalanceObservation",
            targets: ["PhotoBenchWhiteBalanceObservation"]
        ),
        .executable(name: "PhotoBenchBenchmark", targets: ["PhotoBenchBenchmark"]),
        .executable(name: "photobench-render", targets: ["PhotoBenchRender"]),
        .executable(name: "photobench-preview-bench", targets: ["PhotoBenchPreviewBench"]),
        .executable(name: "photobench-engine", targets: ["PhotoBenchEngine"]),
        .executable(name: "niho-camera-cutout", targets: ["NihoCameraCutoutCLI"])
    ],
    targets: [
        .systemLibrary(
            name: "CLibRaw",
            path: "Sources/CLibRaw",
            pkgConfig: "libraw_r",
            providers: [.brew(["libraw"])]
        ),
        .target(
            name: "CLibRawShim",
            dependencies: ["CLibRaw"],
            path: "Sources/CLibRawShim"
        ),
        .target(
            name: "PhotoCore",
            dependencies: ["CLibRawShim"],
            path: "Sources/PhotoCore"
        ),
        .target(
            name: "NihoCameraCutout",
            path: "Sources/NihoCameraCutout"
        ),
        .target(
            name: "PhotoBenchAppSupport",
            dependencies: ["PhotoCore", "NihoCameraCutout"],
            path: "Sources/PhotoBenchAppSupport"
        ),
        .executableTarget(
            name: "PhotoBenchApp",
            dependencies: ["PhotoCore", "PhotoBenchAppSupport", "NihoCameraCutout"],
            path: "Sources/PhotoBenchApp"
        ),
        .executableTarget(
            name: "NihoCameraCutoutCLI",
            dependencies: ["NihoCameraCutout"],
            path: "Sources/NihoCameraCutoutCLI"
        ),
        .executableTarget(
            name: "PhotoBenchCalibration",
            dependencies: ["PhotoCore", "PhotoBenchCalibrationSupport"],
            path: "Sources/PhotoBenchCalibration"
        ),
        .executableTarget(
            name: "PhotoBenchWhiteBalanceObservation",
            dependencies: ["PhotoCore", "PhotoBenchCalibrationSupport"],
            path: "Sources/PhotoBenchWhiteBalanceObservation"
        ),
        .target(
            name: "PhotoBenchCalibrationSupport",
            dependencies: ["PhotoCore"],
            path: "Sources/PhotoBenchCalibrationSupport"
        ),
        .executableTarget(
            name: "PhotoBenchBenchmark",
            dependencies: ["PhotoCore", "PhotoBenchCalibrationSupport"],
            path: "Sources/PhotoBenchBenchmark"
        ),
        .executableTarget(
            name: "PhotoBenchRender",
            dependencies: ["PhotoCore"],
            path: "Sources/PhotoBenchRender"
        ),
        .executableTarget(
            name: "PhotoBenchPreviewBench",
            dependencies: ["PhotoCore"],
            path: "Sources/PhotoBenchPreviewBench"
        ),
        // `photobench-engine --stdio`: PhotoCore as a rendering engine that NIHO
        // Desktop runs as a child process (docs/ENGINE_PROTOCOL.md). Packaged
        // with its Homebrew dylibs by scripts/package-engine.sh.
        .executableTarget(
            name: "PhotoBenchEngine",
            dependencies: ["PhotoCore"],
            path: "Sources/PhotoBenchEngine"
        ),
        .testTarget(
            name: "PhotoCoreTests",
            dependencies: ["PhotoCore", "CLibRawShim"],
            path: "Tests/PhotoCoreTests"
        ),
        .testTarget(
            name: "PhotoBenchAppSupportTests",
            dependencies: ["PhotoBenchAppSupport", "PhotoCore", "NihoCameraCutout"],
            path: "Tests/PhotoBenchAppSupportTests"
        ),
        .testTarget(
            name: "NihoCameraCutoutTests",
            dependencies: ["NihoCameraCutout"],
            path: "Tests/NihoCameraCutoutTests"
        ),
        .testTarget(
            name: "PhotoBenchCalibrationSupportTests",
            dependencies: ["PhotoBenchCalibrationSupport", "PhotoCore"],
            path: "Tests/PhotoBenchCalibrationSupportTests"
        ),
        .testTarget(
            name: "PhotoBenchEngineTests",
            dependencies: ["PhotoBenchEngine", "PhotoCore"],
            path: "Tests/PhotoBenchEngineTests"
        )
    ]
)
