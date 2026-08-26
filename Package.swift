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
            url: "https://github.com/onramper/onramper-ios/releases/download/v1.2.0/OnramperSDK.xcframework.zip",
            checksum: "2d0f28702120326e5ebb191cb2a812b11bf58a9672fcde8cf1762182e96e932b"
        ),
    ]
)
