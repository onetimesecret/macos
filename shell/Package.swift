// swift-tools-version: 6.0
// The shell — Swift/AppKit over the Rust core (ADR-0002, accepted). It
// links the core only through the binary framework produced by
// scripts/build-core.sh — no Swift code holds a secret.
import PackageDescription

let package = Package(
    name: "CompanionPanel",
    platforms: [.macOS(.v13)], // MenuBarExtra needs macOS 13+
    targets: [
        // Produced by scripts/build-core.sh. Exposes the C ABI in
        // crates/ffi/include/companion_ffi.h as the CompanionCore module.
        .binaryTarget(
            name: "CompanionCore",
            path: "../bindings/CompanionCore.xcframework"
        ),
        .executableTarget(
            name: "CompanionPanel",
            dependencies: ["CompanionCore"],
            path: "Sources/CompanionPanel"
        ),
        .testTarget(
            name: "CompanionPanelTests",
            dependencies: ["CompanionPanel"],
            path: "Tests/CompanionPanelTests"
        ),
    ]
)
