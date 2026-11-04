// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnramperSDK",
    platforms: [.iOS(.v16)],
    products: [
        // The SDK alone: the prebuilt binary, no third-party dependencies.
        .library(name: "OnramperSDK", targets: ["OnramperSDK"]),
        // Opt-in: the experimental Stripe Embedded Components checkout (US,
        // USD to USDC, Apple Pay). Adds Stripe's iOS SDK to the app; apps that
        // don't link this product don't build or ship Stripe. It stays
        // dormant until the app calls
        // `StripeCheckout.enable(merchantIdentifier:)` (import OnramperStripe)
        // and requests `onlyOnramps: ["stripe"]`. Using it requires Stripe's
        // onboarding for the app (trusted app + app attestation, Apple Pay
        // merchant) and a `stripe` key on the Onramper partner. Linking it
        // together with `OnramperSDK` is fine: both use the same binary.
        .library(name: "OnramperStripe", targets: ["OnramperStripe"]),
    ],
    dependencies: [
        // Only built for apps that link OnramperStripe (SwiftPM still fetches
        // and resolves it for every app). Pinned exactly:
        // StripeCryptoOnramp is a private-preview SPI whose signatures change
        // between releases.
        .package(url: "https://github.com/stripe/stripe-ios-spm", exact: "26.15.1"),
    ],
    targets: [
        .binaryTarget(
            name: "OnramperSDK",
            url: "https://github.com/onramper/onramper-ios/releases/download/v1.6.0/OnramperSDK.xcframework.zip",
            checksum: "c2536ad456176dd03c1bb5ff4e0d1ecc888655418d1f3d8751cdf687e9690e5a"
        ),
        // Shipped as source: it builds against Stripe's SDK, which cannot be
        // pre-built into a binary, and against OnramperSDK's
        // @_spi(OnramperNative) interface.
        .target(
            name: "OnramperStripe",
            dependencies: [
                "OnramperSDK",
                .product(name: "StripeCryptoOnramp", package: "stripe-ios-spm"),
                .product(name: "StripePaymentSheet", package: "stripe-ios-spm"),
                .product(name: "StripePayments", package: "stripe-ios-spm"),
            ],
            path: "Sources/OnramperStripe"
        ),
    ]
)
