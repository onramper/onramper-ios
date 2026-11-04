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
/// usual terms, OnramperID login and checkout sheet with Stripe's Link and
/// Apple Pay steps inside it. By default a returning Link user signs in to
/// Link before Apple Pay; a new Link user gets Apple Pay first, because
/// registering needs its name and phone. The partner's Stripe setting
/// `linkSignIn: "after_payment"` (or a backend without the setting) keeps
/// Apple Pay first for everyone. Demo and QA builds can override the
/// partner's setting with `linkSignInOverride`. Without this call, or with any other
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

    /// When a returning Link user signs in to Link, relative to Apple Pay.
    /// The raw values are those of the partner setting `metadata.linkSignIn`.
    public enum LinkSignIn: String, Sendable, CaseIterable {
        /// A returning Link user signs in before Apple Pay. A new Link user
        /// still gets Apple Pay first: registering needs its name and phone.
        case beforePayment = "before_payment"
        /// Apple Pay first for everyone (the original order).
        case afterPayment = "after_payment"
    }

    /// Demo and QA override of the partner's Link sign-in order, which the
    /// backend otherwise sends from the partner's Stripe setting
    /// `metadata.linkSignIn`. nil (the default) follows the partner setting.
    ///
    /// Read once when a checkout's Stripe steps start, so a change applies to
    /// the next checkout, never to one in progress. Production apps leave it
    /// nil so Onramper decides the order per partner; it exists so a demo
    /// build can show both orders without changing partner configuration.
    @MainActor public static var linkSignInOverride: LinkSignIn?
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
                            merchantName: merchantName, callbacks: callbacks,
                            linkSignInOverride: StripeCheckout.linkSignInOverride?.rawValue)
    }

    /// `OnramperClient.signOut()`: the Link sign-in kept for this app process
    /// belongs to the user who signed out, so drop it and log it out of Link
    /// (after any closing checkout's cleanup). `signOut()` has already reset
    /// its own client, closing that client's checkout, so a lease still held
    /// is another client's open checkout: the drop then waits for it to end
    /// (`SignOutDrop`). `reset()` alone does not get here: it keeps the Link
    /// sign-in as it keeps the OnramperID login.
    func userSessionEnded() {
        StripeLinkSession.userSignedOut(checkoutOpen: StripeCheckoutModel.isLeaseHeld)
    }
}
#endif
