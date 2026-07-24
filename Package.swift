// swift-tools-version: 5.10
import PackageDescription

// SharedModelStoreKit — the one shared contract for the AI-family apps (Hal,
// Posey, AI Camera) to co-own downloaded models in a common App-Group container.
// This package REPLACES the three hand-copied `SharedModelStore.swift` clones that
// had drifted apart. All three apps import it; the module is the single source of
// truth for the App-Group layout, the co-ownership manifest, the download lock, and
// the pinned model revisions.
//
// Kept deliberately dependency-free (Foundation only) and low-platform so every app
// can adopt it unchanged. Also builds on macOS purely so it can be unit/compile
// tested off-device.
let package = Package(
    name: "SharedModelStoreKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SharedModelStoreKit", targets: ["SharedModelStoreKit"])
    ],
    targets: [
        .target(name: "SharedModelStoreKit"),
        .testTarget(name: "SharedModelStoreKitTests", dependencies: ["SharedModelStoreKit"])
    ]
)
