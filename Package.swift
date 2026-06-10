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
            checksum: "64662328ca5bcc63c236a538d917f6177b3c55136eadbd08e7010a00b3873ed5"
        ),
    ]
)
