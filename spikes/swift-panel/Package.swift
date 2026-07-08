// swift-tools-version: 6.0
// The Swift/AppKit arm of the ADR-0002 shell spike. It links the Rust
// core only through the binary framework produced by
// scripts/build-core.sh — no Swift code holds a secret. A spike, not the
// shell: it graduates to shell/ only if ADR-0002 lands on Swift.
import PackageDescription

let package = Package(
    name: "CompanionPanel",
    platforms: [.macOS(.v13)], // MenuBarExtra needs macOS 13+
    targets: [
        // Produced by scripts/build-core.sh. Exposes the C ABI in
        // crates/ffi/include/companion_ffi.h as the CompanionCore module.
        .binaryTarget(
            name: "CompanionCore",
            path: "../../bindings/CompanionCore.xcframework"
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
