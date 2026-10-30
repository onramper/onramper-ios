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
            checksum: "2080f5aca5cfb9d991360aefceae01714cd23b69af50d11fb3b2cbdb46800c71"
        ),
    ]
)
