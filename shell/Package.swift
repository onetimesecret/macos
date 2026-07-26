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
        // The shared seam wrapper. ADR-0010 let the two form factors
        // carry a copy each while the backdrop was an exploration, and
        // named the extraction as what happens when a sibling
        // graduates. The backdrop gaining persistence graduated it, so
        // both form factors sit on this one wrapper now.
        .target(
            name: "CompanionKit",
            dependencies: ["CompanionCore"],
            path: "Sources/CompanionKit"
        ),
        .testTarget(
            name: "CompanionKitTests",
            dependencies: ["CompanionKit"],
            path: "Tests/CompanionKitTests"
        ),
        .executableTarget(
            name: "CompanionApp",
            dependencies: ["CompanionKit"],
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
            dependencies: ["CompanionKit"],
            path: "Sources/CompanionBackdrop"
        ),
        .testTarget(
            name: "CompanionBackdropTests",
            dependencies: ["CompanionBackdrop"],
            path: "Tests/CompanionBackdropTests"
        ),
    ]
)
