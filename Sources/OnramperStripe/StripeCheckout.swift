#if canImport(UIKit)
import Foundation
@_spi(OnramperNative) import OnramperSDK

/// Turns on the experimental Stripe Embedded Components checkout inside the
/// SDK's normal checkout flow.
///
/// Call once at app start, before the first checkout. From then on a normal
/// `getCheckoutRequirements` call with `onlyOnramps: ["stripe"]` returns the
/// usual `{button, quote}` for a Stripe checkout (USD to USDC on Solana,
/// Ethereum or Base, Apple Pay, up to 100 USD before fees), and Buy runs the
/// usual terms, OnramperID login and checkout sheet with Stripe's Apple Pay
/// and Link steps inside it. Without this call, or with any other
/// `onlyOnramps`, every checkout is the normal flow, unchanged.
///
/// Named `StripeCheckout` rather than after the module: a public type with
/// the module's own name breaks library-evolution interfaces.
public enum StripeCheckout {
    /// - Parameters:
    ///   - merchantIdentifier: Apple Pay merchant ID registered with Stripe
    ///     and present in the app's in-app-payments entitlement (e.g.
    ///     `merchant.com.example`). A checkout fails closed with a
    ///     configuration error if it is not a `merchant.` identifier.
    ///   - merchantName: Apple Pay sheet label, shown as
    ///     "<merchantName> (through Stripe)".
    @MainActor
    public static func enable(merchantIdentifier: String, merchantName: String = "Onramper") {
        NativeCheckoutRegistry.register(StripeCheckoutProvider(merchantIdentifier: merchantIdentifier,
                                                               merchantName: merchantName))
    }
}

/// Builds one `StripeCheckoutModel` per finalized Stripe checkout. The
/// single-coordinator rule is enforced by the model's lease, not here, so a
/// second checkout fails with a clear message instead of sharing Stripe state.
@MainActor
final class StripeCheckoutProvider: NativeCheckoutProvider {
    let providerId = NativeCheckoutRegistry.stripeProviderId
    let merchantIdentifier: String
    let merchantName: String

    init(merchantIdentifier: String, merchantName: String) {
        self.merchantIdentifier = merchantIdentifier
        self.merchantName = merchantName
    }

    func makeSession(context: NativeCheckoutContext, sdk: OnramperClient,
                     callbacks: NativeCheckoutCallbacks) -> any NativeCheckoutSession {
        StripeCheckoutModel(sdk: sdk, context: context, merchantIdentifier: merchantIdentifier,
                            merchantName: merchantName, callbacks: callbacks)
    }
}
#endif
