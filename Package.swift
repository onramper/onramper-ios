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
            checksum: "26cd91f63b8f6ab40a9e572d2ad3f2254151fc66005cd54e88e7f3c787dda4c6"
        ),
    ]
)
