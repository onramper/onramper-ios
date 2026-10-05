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
            url: "https://github.com/onramper/onramper-ios/releases/download/v1.3.0/OnramperSDK.xcframework.zip",
            checksum: "7611f869eab69109b317bb2b81e23c99f9d6f108bb6425ed2aace5cc4d5ad766"
        ),
    ]
)
