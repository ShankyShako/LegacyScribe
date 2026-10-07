// swift-tools-version: 6.2
import PackageDescription

// lsbench: headless STT benchmark (latency, peak memory, WER) over fixture clips.
// MLX needs its Metal library, so build with xcodebuild (see README.md), not `swift build`.
let package = Package(
    name: "lsbench",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "dbe5eaac964e"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.5"),
    ],
    targets: [
        .executableTarget(
            name: "lsbench",
            dependencies: [
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/lsbench"
        ),
    ]
)
