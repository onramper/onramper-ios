// swift-tools-version: 5.9
// Placeholder Package.swift — overwritten by the release workflow on every
// tagged release with a templated manifest pointing at the corresponding
// xcframework asset on this repo's GitHub Releases.
//
// See release-templates/Package.swift.tmpl in the source repo.

import PackageDescription

let package = Package(
    name: "OnramperSDK",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "OnramperSDK", targets: ["OnramperSDK"]),
    ],
    targets: [
        // Replaced at release time with a `.binaryTarget(url:checksum:)` block.
        // Until the first release ships, this package is not consumable.
        .target(
            name: "OnramperSDK",
            path: "_placeholder",
            exclude: ["README.md"]
        ),
    ]
)
