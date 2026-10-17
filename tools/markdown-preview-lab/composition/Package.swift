// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PreviewCompositionLab",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PreviewCompositionLab"),
        .testTarget(name: "PreviewCompositionLabTests", dependencies: ["PreviewCompositionLab"]),
    ]
)
