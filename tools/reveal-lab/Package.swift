// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RevealLab",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "RevealLab")],
    swiftLanguageModes: [.v5]
)
