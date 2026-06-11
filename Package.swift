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
            url: "https://github.com/onramper/onramper-ios/releases/download/v1.0.1/OnramperSDK.xcframework.zip",
            checksum: "3b0ef3356d46bdda6f3dc29043e3f00a9386bfa3411ce3115f2d479044458740"
        ),
    ]
)
