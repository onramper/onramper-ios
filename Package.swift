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
            url: "https://github.com/onramper/onramper-ios/releases/download/v1.4.0/OnramperSDK.xcframework.zip",
            checksum: "098ee1386e443fdd486f4bf07292993c25887464e96599c0952a7ea4e1560b37"
        ),
    ]
)
