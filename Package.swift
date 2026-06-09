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
            checksum: "c644d91bc2fb03e79213e5c326310875a07889ab8ba009bc29449ea7517590bf"
        ),
    ]
)
