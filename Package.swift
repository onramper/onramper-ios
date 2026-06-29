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
            url: "https://github.com/onramper/onramper-ios/releases/download/v1.1.0/OnramperSDK.xcframework.zip",
            checksum: "ff638a874587498611915af37ca05a26ebddd4a3be6c44af50edb40a348fc2b8"
        ),
    ]
)
