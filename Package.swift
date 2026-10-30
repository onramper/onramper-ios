// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OnramperSDK",
    platforms: [.iOS(.v16)],
    products: [
        // One product. It carries the OnramperStripe module too: the Stripe
        // Embedded Components checkout (US, USD to USDC, Apple Pay). It stays
        // dormant until the app calls
        // `StripeCheckout.enable(merchantIdentifier:)` (import OnramperStripe)
        // and requests `onlyOnramps: ["stripe"]`. Using it requires Stripe's
        // onboarding for the app (trusted app + app attestation, Apple Pay
        // merchant) and a `stripe` key on the Onramper partner.
        .library(name: "OnramperSDK", targets: ["OnramperSDK", "OnramperStripe"]),
    ],
    dependencies: [
        // Built into every app that links OnramperSDK. Pinned exactly:
        // StripeCryptoOnramp is a private-preview SPI whose signatures change
        // between releases.
        .package(url: "https://github.com/stripe/stripe-ios-spm", exact: "26.15.1"),
    ],
    targets: [
        .binaryTarget(
            name: "OnramperSDK",
            url: "https://github.com/onramper/onramper-ios/releases/download/v1.5.0/OnramperSDK.xcframework.zip",
            checksum: "ac2ba976a5a1ebcd5462291088cbb213df3c2dd0fb62ece0f3c95d265ee835f8"
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
