// swift-tools-version: 6.0
// The shell — Swift/AppKit over the Rust core (ADR-0002, accepted). It
// links the core only through the binary framework produced by
// scripts/build-core.sh — no Swift code holds a secret.
import PackageDescription

let package = Package(
    name: "OnetimePad",
    platforms: [.macOS(.v13)], // MenuBarExtra needs macOS 13+
    targets: [
        // Produced by scripts/build-core.sh. Exposes the C ABI in
        // crates/ffi/include/companion_ffi.h as the CompanionCore module.
        .binaryTarget(
            name: "CompanionCore",
            path: "../bindings/CompanionCore.xcframework"
        ),
        // Everything the app is above its window: the seam wrapper, the
        // page model, and the views that render pages, chips, the ledger
        // and the exit ramp. Extracted when the backdrop graduated
        // (ADR-0010); kept separate from the executable target so a
        // future form factor starts from here rather than from a fork.
        // What lives in an executable target is its window and its
        // posture.
        // Carries the brand art (Resources/onetime-logo-v3-xl.svg) that
        // LogoMark draws the status item from, so the menu bar shows the
        // same mark scripts/render-icon.swift bakes into the app icon.
        .target(
            name: "CompanionKit",
            dependencies: ["CompanionCore"],
            path: "Sources/CompanionKit",
            resources: [.process("Resources")]
        ),
        // The shared code's tests, which is now every unit-testable
        // decision the app makes. The executable target keeps only
        // AppKit plumbing, which the project tests by hand on hardware
        // (docs/hardware-verification.md) rather than by mocking.
        // CompanionCore is a direct dependency because the suite calls
        // `companion_new_ephemeral` itself (EphemeralClient.swift): the
        // seam exists only in test-util builds of the core (ADR-0018),
        // so the reference must live here rather than in any shipping
        // target. Running these tests therefore takes the dev
        // xcframework: scripts/build-core.sh --test-util.
        .testTarget(
            name: "CompanionKitTests",
            dependencies: ["CompanionKit", "CompanionCore"],
            path: "Tests/CompanionKitTests"
        ),
        // OnetimePad, the background-surface form factor (ADR-0010,
        // ADR-0014). The panel sibling (CompanionApp) was archived once
        // this target reached parity; its sources live in git history.
        .executableTarget(
            name: "OnetimePad",
            dependencies: ["CompanionKit"],
            path: "Sources/OnetimePad"
        ),
        .testTarget(
            name: "OnetimePadTests",
            dependencies: ["OnetimePad"],
            path: "Tests/OnetimePadTests"
        ),
    ]
)
