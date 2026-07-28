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
            url: "https://github.com/onramper/onramper-ios/releases/download/v1.1.1/OnramperSDK.xcframework.zip",
            checksum: "88235fa50561422ba3276f8008ff0a2229cff760f75f36f3f424ff5f26e2b2e2"
        ),
    ]
)
