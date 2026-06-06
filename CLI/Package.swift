// swift-tools-version: 5.10
//
// Multi-command PhotoX CLI. `photox index <folder>` is today's
// sidecar producer (the NAS pre-indexer); future subcommands live
// alongside it. IndexingCore is the shared library that the
// macOS app also consumes (via local SwiftPM dependency on this
// package), keeping per-photo extraction logic in one place across
// host platforms.
import PackageDescription

let package = Package(
    name: "Indexer",
    platforms: [
        .macOS("15.0"),
    ],
    products: [
        .library(name: "IndexingCore", targets: ["IndexingCore"]),
        // Multi-command CLI — `photox index <folder>` for the
        // sidecar producer today; future subcommands slot in
        // alongside without breaking the binary name.
        .executable(name: "photox", targets: ["photox"]),
    ],
    targets: [
        .target(name: "IndexingCore"),
        .testTarget(name: "IndexingCoreTests", dependencies: ["IndexingCore"]),
        .executableTarget(
            name: "photox",
            dependencies: ["IndexingCore"]
        ),
    ]
)
