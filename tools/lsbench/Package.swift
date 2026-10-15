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
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.32.3"),
        // mlx-swift 0.32.3 plus the `_updateInternal` leak fix (the app pins the same commit).
        .package(url: "https://github.com/ShankyShako/mlx-swift.git", revision: "37407d1ca8c3d138e993d5ef84ac48a13793f0dc"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.1.6"),
        .package(path: "../../HexCore"),
    ],
    targets: [
        .executableTarget(
            name: "lsbench",
            dependencies: [
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HexCore", package: "HexCore"),
            ],
            path: "Sources/lsbench"
        ),
    ]
)
