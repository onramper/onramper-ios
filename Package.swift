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
            url: "https://github.com/onramper/onramper-ios/releases/download/v1.3.1/OnramperSDK.xcframework.zip",
            checksum: "c003eb348062fb755d3de304f1f7ea4f1a7253192fa7e33adb794f2ce1d90d6a"
        ),
    ]
)
