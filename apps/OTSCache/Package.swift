// swift-tools-version: 5.9
// The Swift/SwiftUI shell for OTS Cache (docs/01 §7). It links the Rust trust
// core only through the generated binary framework — no Swift code holds a
// secret. Start life as a SwiftPM package for CI-friendliness; graduate to an
// .xcodeproj when signing/entitlements require it.
//
// Tools version is 5.9 to match the Swift toolchain on the macOS CI runner
// (macos-14 ships Xcode 15 / Swift 5.10). The sources use no 6.0-only syntax,
// so nothing here needs it yet. Raise the floor to 6.0 once the runner's Xcode
// baseline moves and we adopt the Swift 6 language mode deliberately (which
// turns on strict concurrency — a change to make on purpose, not by accident).
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
