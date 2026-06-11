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
            checksum: "d547e76f41eb19b058489e3f523bdefaa19ba77f872cb2fa2fe7b4120cda404d"
        ),
    ]
)
