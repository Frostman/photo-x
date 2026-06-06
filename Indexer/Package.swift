// swift-tools-version: 5.10
//
// PhotoX indexing primitives, factored out of the macOS app so the
// same logic can run on a Linux NAS that pre-indexes shoots and
// writes a sidecar plist (.photox-index.plist) the app prefer-loads
// on shoot open.
//
// Stage 1: the IndexingCore library exposes only the sidecar schema
// + a read/write API. Stage 2 moves the per-file extraction code
// (HEIF/JPEG box parsing, TIFF EXIF, exiftool batch runner) into
// this package. Stage 5 adds the photox-indexer executable target.
import PackageDescription

let package = Package(
    name: "Indexer",
    platforms: [
        .macOS("15.0"),
    ],
    products: [
        .library(name: "IndexingCore", targets: ["IndexingCore"]),
        // Binary name is hyphenated (matches the macOS-app CLI
        // naming convention); target name uses an underscore so
        // SwiftPM accepts it as a module identifier.
        .executable(name: "photox-indexer", targets: ["photox_indexer"]),
    ],
    targets: [
        .target(name: "IndexingCore"),
        .testTarget(name: "IndexingCoreTests", dependencies: ["IndexingCore"]),
        .executableTarget(
            name: "photox_indexer",
            dependencies: ["IndexingCore"],
            path: "Sources/photox-indexer"
        ),
    ]
)
