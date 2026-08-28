// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FocusedRendering",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FoveatedStreamingProtocol", targets: ["FoveatedStreamingProtocol"]),
        .library(name: "FoveatedStreamingHost", targets: ["FoveatedStreamingHost"]),
        .library(name: "FoveationBenchmark", targets: ["FoveationBenchmark"]),
        .library(name: "FoveatedPipeline", targets: ["FoveatedPipeline"]),
        .executable(name: "fr-host", targets: ["fr-host"]),
        .executable(name: "fr-bench", targets: ["fr-bench"]),
        .executable(name: "fr-pipeline", targets: ["fr-pipeline"]),
    ],
    targets: [
        .target(name: "FoveatedStreamingProtocol"),
        .target(name: "FoveatedStreamingHost", dependencies: ["FoveatedStreamingProtocol"]),
        .executableTarget(name: "fr-host", dependencies: ["FoveatedStreamingHost"]),
        .target(name: "FoveationBenchmark"),
        .executableTarget(name: "fr-bench", dependencies: ["FoveationBenchmark"]),
        .target(name: "FoveatedPipeline", dependencies: ["FoveationBenchmark"]),
        .executableTarget(name: "fr-pipeline", dependencies: ["FoveatedPipeline"]),
        .testTarget(name: "FoveatedStreamingProtocolTests", dependencies: ["FoveatedStreamingProtocol"]),
        .testTarget(name: "FoveatedStreamingHostTests", dependencies: ["FoveatedStreamingHost"]),
        .testTarget(name: "FoveationBenchmarkTests", dependencies: ["FoveationBenchmark"]),
        .testTarget(name: "FoveatedPipelineTests", dependencies: ["FoveatedPipeline"]),
    ],
    swiftLanguageModes: [.v6]
)
