// swift-tools-version: 6.0
// The shell — Swift/AppKit over the Rust core (ADR-0002, accepted). It
// links the core only through the binary framework produced by
// scripts/build-core.sh — no Swift code holds a secret.
import PackageDescription

let package = Package(
    name: "CompanionApp",
    platforms: [.macOS(.v13)], // MenuBarExtra needs macOS 13+
    targets: [
        // Produced by scripts/build-core.sh. Exposes the C ABI in
        // crates/ffi/include/companion_ffi.h as the CompanionCore module.
        .binaryTarget(
            name: "CompanionCore",
            path: "../bindings/CompanionCore.xcframework"
        ),
        .executableTarget(
            name: "CompanionApp",
            dependencies: ["CompanionCore"],
            path: "Sources/CompanionApp"
        ),
        .testTarget(
            name: "CompanionAppTests",
            dependencies: ["CompanionApp"],
            path: "Tests/CompanionAppTests"
        ),
        // The background-surface form factor (ADR-0010): a sibling
        // target over the same core, exploring the desktop-canvas
        // posture without touching the panel app's sources.
        .executableTarget(
            name: "CompanionBackdrop",
            dependencies: ["CompanionCore"],
            path: "Sources/CompanionBackdrop"
        ),
        .testTarget(
            name: "CompanionBackdropTests",
            dependencies: ["CompanionBackdrop"],
            path: "Tests/CompanionBackdropTests"
        ),
    ]
)
