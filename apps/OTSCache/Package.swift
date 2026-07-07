// swift-tools-version: 6.0
// The Swift/SwiftUI shell for OTS Cache (docs/01 §7). It links the Rust trust
// core only through the generated binary framework — no Swift code holds a
// secret. Start life as a SwiftPM package for CI-friendliness; graduate to an
// .xcodeproj when signing/entitlements require it.
import PackageDescription

let package = Package(
    name: "OTSCache",
    platforms: [.macOS(.v13)], // MenuBarExtra needs macOS 13+
    targets: [
        // Produced by scripts/build-core.sh. Exposes the C ABI in crates/
        // ots-ffi/include/ots_ffi.h as the `OtsCore` module.
        .binaryTarget(
            name: "OtsCore",
            path: "../../bindings/OtsCore.xcframework"
        ),
        .executableTarget(
            name: "OTSCache",
            dependencies: ["OtsCore"],
            path: "Sources/OTSCache"
        ),
        .testTarget(
            name: "OTSCacheTests",
            dependencies: ["OTSCache"],
            path: "Tests/OTSCacheTests"
        ),
    ]
)
