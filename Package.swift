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
            url: "https://github.com/onramper/onramper-ios/releases/download/v1.4.1/OnramperSDK.xcframework.zip",
            checksum: "a4b708ead056a7943616400c533d6b3294f67054b90ea79957d52ad125d11521"
        ),
    ]
)
