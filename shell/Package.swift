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
        // Everything both form factors are: the seam wrapper, the page
        // model, and the views that render pages, chips, the ledger and
        // the exit ramp. ADR-0010 let the two targets carry a copy each
        // while the backdrop was an exploration, and named the
        // extraction as what happens when a sibling graduates.
        // Persistence graduated it once, for the wrapper; feature parity
        // graduated the rest. What is left in a form factor's own target
        // is its window and its posture.
        .target(
            name: "CompanionKit",
            dependencies: ["CompanionCore"],
            path: "Sources/CompanionKit"
        ),
        // The shared code's tests, which is now every unit-testable
        // decision either app makes. The form-factor targets keep only
        // AppKit plumbing, which the project tests by hand on hardware
        // (docs/hardware-verification.md) rather than by mocking.
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
