// The Link sign-in kept across Stripe checkouts in one app process, and the
// pure rules around it.
//
// Stripe keeps a Link session in memory only, on the `CryptoOnrampCoordinator`
// that signed in. Creating a coordinator per checkout and logging it out at
// the end made every purchase sign in to Link again (often with Link's OTP).
// Instead the coordinator of the last checkout is kept for the app process
// (`StripeLinkSession`), and the next checkout asks the backend to reuse the
// stored Link authorization (`reuse_auth`) before Apple Pay. After an app
// relaunch nothing is held and Link's sign-in runs as before.
//
// The rules below are deliberately NOT behind `#if canImport(UIKit)`: they
// need only Foundation, so their tests also run under `swift test` on macOS.
// The holder itself stores a Stripe coordinator and is iOS only.
import Foundation

/// Whose Link sign-in a held coordinator carries: the partner's Stripe
/// account (its publishable key, which also fixes test or live mode) and the
/// OnramperID email the backend hands out at finalize. Both come from the
/// finalize response's `providerContext`.
struct LinkSessionOwner: Equatable, Sendable {
    let publishableKey: String
    let email: String
}

/// Pure decisions around the held Link sign-in, kept separate so they are
/// unit tested without a Stripe coordinator.
enum LinkSessionRules {
    /// v2 continue action that asks the backend to reuse the stored Link
    /// authorization of this OnramperID user for `customerId`.
    static let reuseAction = "reuse_auth"
    /// Backend reason when `reuse_auth` is not possible (nothing stored,
    /// refresh rejected, a different customer, busy, ...). The checkout stays
    /// in `collect_payment` and continues with the normal Link sign-in.
    static let unavailableReason = "link_reuse_unavailable"

    /// Whether a checkout may keep using the held coordinator. Exact match
    /// on both fields: a different Stripe account or OnramperID email must
    /// never inherit someone's Link sign-in, and a false "different" only
    /// costs one Link sign-in. Anything else drops (and logs out) the held
    /// coordinator before a new one is created.
    static func canReuse(held: LinkSessionOwner?, for current: LinkSessionOwner) -> Bool {
        held == current
    }

    /// What the checkout does after the `reuse_auth` response.
    enum AfterReuse: Equatable {
        /// The backend stopped the checkout: end it like any backend stop,
        /// before Apple Pay is ever shown.
        case stop
        /// The reuse was accepted (`verify` or `ready`, exactly as after
        /// `complete_auth`): Apple Pay, then straight on to `drive` with no
        /// Link lookup, registration, `start_auth`, authorize or
        /// `complete_auth`.
        case applePay
        /// The reuse was accepted, but its next step is one `drive` cannot
        /// run after Apple Pay: fail before Face ID, as the sign-in before
        /// Apple Pay does (`StripeCheckoutModel.afterReuse`, iOS only).
        case unsupported
        /// Not reused: today's flow (Apple Pay, lookup, `start_auth`,
        /// authorize, `complete_auth`) on the finalize response.
        case fallback
    }

    /// Pure mapping of a `reuse_auth` response. A backend stop is final, as
    /// everywhere else in this module. `link_reuse_unavailable` falls back
    /// whatever the status. Any status other than `verify` or `ready` falls
    /// back too: the backend validates every later step, so the normal flow
    /// is the safe default for a response this SDK does not understand.
    /// (Errors from the call itself also fall back; see `reuseLinkSession`.)
    static func afterReuse(status: String, reason: String?) -> AfterReuse {
        if status == "stopped" { return .stop }
        if reason == unavailableReason { return .fallback }
        switch status {
        case "verify", "ready": return .applePay
        default: return .fallback
        }
    }

    /// Whether the Apple Pay sheet asks for (and the contact check after it
    /// requires) the Wallet phone. Only registering a NEW Link user uses the
    /// phone, and a checkout whose Link step is already done (`reuse_auth`
    /// accepted this app session's sign-in) registers nobody, so it never
    /// asks. Before Apple Pay a normal checkout cannot know whether the
    /// email has a Link account (the lookup comes after), so it still asks.
    static func requestsPhone(linkAuthorized: Bool) -> Bool { !linkAuthorized }

    /// Stripe API error codes meaning the Link consumer session behind the
    /// held coordinator is no longer valid. Link already refreshes the
    /// session once on these (`retryingOnAuthError` in StripePaymentSheet's
    /// `PaymentSheetLinkAccount`); seeing one here means that refresh failed
    /// too. Mirrors `authErrorCodes` in StripePaymentSheet `Error+Link.swift`
    /// (stripe-ios 26.15.1).
    static let sessionGoneCodes: Set<String> = ["consumer_session_credentials_invalid", "consumer_session_expired"]
}

/// An OnramperID sign-out's drop of the held Link sign-in.
///
/// `signOut()` first resets its own client, which closes that client's
/// checkout and frees the single-coordinator lease. A lease still held after
/// that belongs to ANOTHER `OnramperClient`'s open checkout, which may be
/// inside a Link call on the held coordinator: logging it out then would
/// break that checkout. So the drop waits until that checkout ends (it
/// closes, or the next checkout starts), and then drops only the coordinator
/// held at sign-out, if it is still held. If the open checkout belongs to
/// another user, its own coordinator replaced the old one and stays.
///
/// Generic over the coordinator so it is unit tested without Stripe.
struct SignOutDrop<Coordinator: AnyObject> {
    enum When: Equatable { case now, whenCheckoutEnds }

    private var pending: Coordinator?

    /// Decides when the coordinator held at sign-out is dropped. `.now`:
    /// the caller drops it at once (and any earlier pending drop is covered).
    mutating func signOut(held: Coordinator?, checkoutOpen: Bool) -> When {
        guard checkoutOpen else {
            pending = nil
            return .now
        }
        pending = held
        return .whenCheckoutEnds
    }

    /// The coordinator to drop now that the open checkout ended, at most once.
    mutating func checkoutEnded() -> Coordinator? {
        defer { pending = nil }
        return pending
    }
}

#if canImport(UIKit)
@_spi(CryptoOnrampAlpha) import StripeCryptoOnramp
// `LinkController.IntegrationError` (the "no Link session" error) is Stripe's
// own `STP` SPI; this file is the only one that imports it.
@_spi(STP) import StripePaymentSheet

/// The Link sign-in of this app process: the coordinator the last Stripe
/// checkout used, kept after it so the next checkout can skip Link.
///
/// One at a time, like the coordinator lease (`StripeCheckoutModel`):
/// Stripe documents that its shared state supports a single coordinator.
/// Dropped (and logged out) when the next checkout is for a different Stripe
/// key or email, when the OnramperID user signs out
/// (`StripeCheckoutProvider.userSessionEnded`; after another client's open
/// checkout ends, see `SignOutDrop`), and when a Link call fails
/// because the session is gone (`isSessionGone`). Never persisted: an app
/// relaunch starts with nothing held.
@MainActor
enum StripeLinkSession {
    /// The held coordinator and what it is known to carry.
    @MainActor
    final class Held {
        let coordinator: CryptoOnrampCoordinator
        let owner: LinkSessionOwner
        /// The crypto customer of the Link sign-in this coordinator holds,
        /// recorded once `complete_auth` accepted it. Nil until then: the
        /// coordinator was created, but nobody signed in to Link through it.
        fileprivate(set) var customerId: String?

        fileprivate init(coordinator: CryptoOnrampCoordinator, owner: LinkSessionOwner) {
            self.coordinator = coordinator
            self.owner = owner
        }
    }

    private(set) static var held: Held?

    /// Work that touches Stripe's shared state after a checkout ended: a
    /// closed checkout's wait for its cancelled operation and its backend
    /// cancel, and a dropped coordinator's `logOut`. Chained, so each item
    /// runs after every earlier one. A checkout waits for all of it before it
    /// uses or creates a coordinator: Stripe's Link account is process-wide,
    /// so a late `logOut` must not land on the next checkout's sign-in, and
    /// a reused coordinator must not be shared with a closing operation.
    private static var cleanup: Task<Void, Never>?

    /// Queues `work` behind every cleanup queued before it.
    static func afterCleanup(_ work: @escaping @MainActor () async -> Void) {
        let previous = cleanup
        cleanup = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Returns once every cleanup queued so far has finished.
    static func cleanupFinished() async {
        await cleanup?.value
    }

    /// Keeps `coordinator` for later checkouts by the same owner, dropping
    /// whatever was held before.
    static func hold(_ coordinator: CryptoOnrampCoordinator, for owner: LinkSessionOwner) {
        if let current = held, current.coordinator !== coordinator { drop() }
        held = Held(coordinator: coordinator, owner: owner)
    }

    /// Records the crypto customer once `complete_auth` accepted a Link
    /// sign-in through `coordinator`. Ignored when that coordinator is no
    /// longer held (dropped by a sign-out while the checkout was finishing),
    /// so a late call never brings a dropped sign-in back.
    static func recordSignIn(customerId: String, on coordinator: CryptoOnrampCoordinator) {
        guard let held, held.coordinator === coordinator else { return }
        held.customerId = customerId
    }

    /// Forgets the held coordinator now and logs it out of Link once the
    /// queued cleanup has finished. With `coordinator`, only if that one is
    /// still the held one. The Stripe `logOut` error is ignored: the
    /// coordinator is never used again either way.
    static func drop(_ coordinator: CryptoOnrampCoordinator? = nil) {
        guard let current = held else { return }
        if let coordinator, current.coordinator !== coordinator { return }
        held = nil
        afterCleanup { try? await current.coordinator.logOut() }
    }

    private static var signOutDrop = SignOutDrop<CryptoOnrampCoordinator>()

    /// `OnramperClient.signOut()`: drops the held Link sign-in now, or, when
    /// another client's checkout is still open (`checkoutOpen`), once that
    /// checkout ends (`checkoutEnded`). See `SignOutDrop`.
    static func userSignedOut(checkoutOpen: Bool) {
        switch signOutDrop.signOut(held: held?.coordinator, checkoutOpen: checkoutOpen) {
        case .now: drop()
        case .whenCheckoutEnds: break
        }
    }

    /// A checkout closed, or a new one is starting with the lease free (the
    /// last holder may have been deallocated without closing): runs a
    /// sign-out drop that waited for it. Its `logOut` queues behind the
    /// closed checkout's cleanup, like any drop.
    static func checkoutEnded() {
        if let coordinator = signOutDrop.checkoutEnded() { drop(coordinator) }
    }

    /// Whether `error` means the Link session behind a coordinator is gone,
    /// so it must be dropped and the next checkout must sign in again:
    /// - `LinkController.IntegrationError.noActiveLinkConsumer`: the
    ///   coordinator has no Link account (StripeCryptoOnramp's
    ///   `linkAccountInfo`, `CryptoOnrampCoordinator.swift`, used by
    ///   `attachKYCInfo`, `registerWalletAddress` and others);
    /// - `CryptoOnrampCoordinator.Error.linkAccountNotVerified`: a Link
    ///   account that is not verified;
    /// - a Stripe API error whose code is in `sessionGoneCodes` (the consumer
    ///   session expired and Link's own refresh failed).
    static func isSessionGone(_ error: Error) -> Bool {
        if case .noActiveLinkConsumer? = error as? LinkController.IntegrationError { return true }
        if case .linkAccountNotVerified? = error as? CryptoOnrampCoordinator.Error { return true }
        if let code = (error as? StripeCryptoOnrampError)?.code ?? (error as NSError).userInfo["com.stripe.lib:StripeErrorCodeKey"] as? String {
            return LinkSessionRules.sessionGoneCodes.contains(code)
        }
        return false
    }
}
#endif
