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
            url: "https://github.com/onramper/onramper-ios/releases/download/v1.2.2/OnramperSDK.xcframework.zip",
            checksum: "754184c10a736e1db3292b592ca634ddbaa61dd01540b60610df4aa73a61de9a"
        ),
    ]
)
