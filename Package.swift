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
            url: "https://github.com/onramper/onramper-ios/releases/download/v1.0.0/OnramperSDK.xcframework.zip",
            checksum: "bd0697e80b0ca0a49c83f84969d5a0cccd6bfd4b3b83639eee9d6b000fb586b2"
        ),
    ]
)
