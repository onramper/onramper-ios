// Post-finalize calls of the headless v2 Stripe checkout
// (`/headless/v2/checkout/continue`, `GET /{id}/status`) and the failures the
// Stripe session reports. The wire types themselves (`V2CheckoutSnapshot`,
// `V2ContinueBody`, ...) live in OnramperSDK, which runs intent and finalize
// through the normal checkout flow.
//
// Deliberately NOT behind `#if canImport(UIKit)`: it needs only Foundation and
// OnramperSDK, so its tests also run under `swift test` on macOS.
import Foundation
@_spi(OnramperNative) import OnramperSDK

@MainActor
struct CheckoutAPI {
    let sdk: OnramperClient

    func advance(_ id: UUID, action: String, customerId: String? = nil, paymentToken: String? = nil) async throws -> V2CheckoutSnapshot {
        // Encoded once; the transport reuses these bytes (and so this
        // requestId) across token refreshes. A new call is a new action.
        let body = V2ContinueBody(headlessCheckoutId: id, requestId: UUID(), action: action,
                                  customerId: customerId, paymentToken: paymentToken)
        return try decode(await sdk.v2Request(route: .continuation, body: JSONEncoder().encode(body)))
    }

    func status(_ id: UUID) async throws -> V2CheckoutSnapshot {
        try decode(await sdk.v2Request(route: .status(id)))
    }

    private func decode(_ data: Data) throws -> V2CheckoutSnapshot {
        let value = try JSONDecoder().decode(V2CheckoutSnapshot.self, from: data)
        guard value.provider == NativeCheckoutRegistry.stripeProviderId else { throw CheckoutFailure.unavailable }
        return value
    }
}

/// Failures the Stripe session reports. `userMessage` is fixed copy (never
/// raw error text) and reaches the SDK's failed screen as
/// `OnramperError.providerFailed` / `.paymentFailed`; the type is a plain enum
/// so `ErrorSummary` logs it as a stable `CheckoutFailure.<case>` code.
enum CheckoutFailure: Error, Equatable {
    case unavailable, contactDetails, changedPrice, cancelled, configuration, applePayUnavailable, busy, timedOut
    /// The backend stopped this checkout. `reason` is its stable reason code
    /// (e.g. `pricing_changed`, `payment_rejected`); `restart` means a fresh
    /// quote can succeed.
    case stopped(reason: String?, restart: Bool)

    var userMessage: String {
        switch self {
        case .unavailable: return "This checkout needs a step that is not supported yet. No further payment attempt was made."
        case .contactDetails: return "Apple Pay did not provide complete US contact details. Update your Wallet details and start a new checkout."
        case .changedPrice: return "The quote expired or the price changed. Start again to review fresh pricing."
        case .cancelled: return "Checkout cancelled."
        case .configuration: return "Stripe Apple Pay is not configured for this build."
        case .applePayUnavailable: return "Apple Pay is not available on this device. Add a supported card to Wallet and try again."
        case .busy: return "Another Stripe checkout is still closing. Close this screen and try again."
        // Only reported before payment: once the payment is submitted the
        // SDK is in `.paymentPending` and a slow delivery leaves it there.
        case .timedOut: return "This is taking longer than expected. No payment was made. Start a new checkout to try again."
        case .stopped(let reason, let restart):
            if restart { return CheckoutFailure.changedPrice.userMessage }
            // The reason is a backend enum code, safe to show and useful in support reports.
            return "Checkout stopped (\(reason ?? "unknown")). No further payment attempt will be made. Start a new checkout to try again."
        }
    }

    /// After `performCheckout` was invoked but before it confirmed the
    /// payment: the charge may or may not have happened.
    static let unconfirmedPaymentMessage =
        "Payment status could not be confirmed. Check this checkout before starting another payment."
}
