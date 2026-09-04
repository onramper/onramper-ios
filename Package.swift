// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnramperSDK",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "OnramperSDK", targets: ["OnramperSDK"]),
    ],
    targets: [
        .binaryTarget(
            name: "OnramperSDK",
            url: "https://github.com/onramper/onramper-ios/releases/download/v1.2.1/OnramperSDK.xcframework.zip",
            checksum: "305cca364bb24bb5ec964488e1dc815a9a63c734a989482080cbc02993ec7f6b"
        ),
    ]
)
