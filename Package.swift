// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FocusedRendering",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FoveatedStreamingProtocol", targets: ["FoveatedStreamingProtocol"]),
        .library(name: "FoveatedStreamingHost", targets: ["FoveatedStreamingHost"]),
        .executable(name: "fr-host", targets: ["fr-host"]),
    ],
    targets: [
        .target(name: "FoveatedStreamingProtocol"),
        .target(name: "FoveatedStreamingHost", dependencies: ["FoveatedStreamingProtocol"]),
        .executableTarget(name: "fr-host", dependencies: ["FoveatedStreamingHost"]),
        .testTarget(name: "FoveatedStreamingProtocolTests", dependencies: ["FoveatedStreamingProtocol"]),
        .testTarget(name: "FoveatedStreamingHostTests", dependencies: ["FoveatedStreamingHost"]),
    ],
    swiftLanguageModes: [.v6]
)
