// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FocusedRendering",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FoveatedStreamingProtocol", targets: ["FoveatedStreamingProtocol"]),
        .library(name: "FoveatedStreamingHost", targets: ["FoveatedStreamingHost"]),
        .library(name: "FoveationBenchmark", targets: ["FoveationBenchmark"]),
        .executable(name: "fr-host", targets: ["fr-host"]),
        .executable(name: "fr-bench", targets: ["fr-bench"]),
    ],
    targets: [
        .target(name: "FoveatedStreamingProtocol"),
        .target(name: "FoveatedStreamingHost", dependencies: ["FoveatedStreamingProtocol"]),
        .executableTarget(name: "fr-host", dependencies: ["FoveatedStreamingHost"]),
        .target(name: "FoveationBenchmark"),
        .executableTarget(name: "fr-bench", dependencies: ["FoveationBenchmark"]),
        .testTarget(name: "FoveatedStreamingProtocolTests", dependencies: ["FoveatedStreamingProtocol"]),
        .testTarget(name: "FoveatedStreamingHostTests", dependencies: ["FoveatedStreamingHost"]),
        .testTarget(name: "FoveationBenchmarkTests", dependencies: ["FoveationBenchmark"]),
    ],
    swiftLanguageModes: [.v6]
)
