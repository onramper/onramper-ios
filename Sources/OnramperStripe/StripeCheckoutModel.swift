#if canImport(UIKit)
import Foundation
import PassKit
@_spi(OnramperNative) import OnramperSDK
@_spi(CryptoOnrampAlpha) import StripeCryptoOnramp
@_spi(CryptoOnrampAlpha) import StripePaymentSheet
import StripePayments

import SwiftUI

/// Runs the post-finalize steps of one Stripe Embedded Components checkout as
/// the SDK's native payment session, in one ordering:
///
/// 1. `prepareApplePay`: the finalize response, Apple Pay support and the
///    merchant id are checked first, so a device that cannot pay never sees
///    Link. Then the Stripe coordinator held for this app process
///    (`StripeLinkSession`) is reused when it belongs to the same Stripe key
///    and OnramperID email; otherwise the old one is dropped and a new one is
///    created and held.
/// 2. Link reuse (`reuseLinkSession`): when the held coordinator carries a
///    Link customer, the backend is asked to reuse that sign-in
///    (`reuse_auth`). Accepted: Link is done with no Link UI, then Apple Pay
///    (no phone) -> `drive`. Stopped: the checkout ends before Apple Pay.
/// 3. Otherwise (nothing held, reuse unavailable, or any reuse error) the
///    Link sign-in order applies (`beforeApplePay`); the setting is
///    `StripeCheckout.linkSignInOverride` ?? the partner's
///    `providerContext.linkSignIn` from finalize:
///    - `before_payment` (the backend default) and an existing Link account:
///      an early sign-in pass (Link lookup -> `start_auth` -> Link's code
///      screen -> `complete_auth`) -> Apple Pay (no phone) -> `drive`.
///      Stripe's eligibility checks answer at `complete_auth`, so a stopped
///      checkout ends before Apple Pay ever shows (Stripe's SDK asks for this
///      order: "authenticate the customer before collecting Apple Pay"). The
///      pass presents from the view's controller; with none within 5 s it
///      falls back to Apple Pay first.
///    - otherwise the original order: Apple Pay -> Link (look up, register a
///      new user, authorize) -> `drive`. Used for `after_payment`, a backend
///      that sends no setting, and a NEW Link user under `before_payment`
///      (registering needs the name and phone from Apple Pay).
/// 4. `drive`: KYC L0 -> wallet + payment token -> `performCheckout` ->
///    status polling. When Apple Pay was collected before the Link customer
///    existed (the original order) and Stripe then rejects the payment token
///    with a KYC region change, Apple Pay is collected once more on the same
///    coordinator and the token retried once (`recollectApplePay`).
///
/// Rules across the orders:
/// - Every successful Link sign-in (early pass or original order) records the
///   customer on the held coordinator (`StripeLinkSession.recordSignIn`, in
///   `authorizeLink`), so the next checkout in this app process can reuse it.
/// - Link `logOut` happens only through `StripeLinkSession.drop`: on
///   `OnramperClient.signOut()`, an owner change (another Stripe key or
///   email) or a dead Link session. Never when a checkout ends and never on
///   `reset()`: a user is never logged out unless they ask. After an app
///   relaunch nothing is held and Link's sign-in runs as before.
/// - One `linkAuthorized` flag (set by an accepted reuse or by the early
///   pass) and one phone rule: Apple Pay asks for no phone whenever the user
///   is signed in before it (`LinkSessionRules.requestsPhone`).
/// - Logs: `link.session` once per checkout that reaches the reuse decision;
///   `link.order` once, only when the order is actually decided (never after
///   an accepted reuse; see `logLinkOrder`).
///
/// Everything before that is the SDK's normal flow, which this model never
/// sees: the quote and Buy button from `getCheckoutRequirements`, Link's terms
/// under Buy (the tap is the acceptance), OnramperID login and the v2
/// finalize. The SDK creates this model after finalize (see
/// `StripeCheckoutProvider`), shows its view inside the normal checkout sheet
/// and owns it, so polling continues after the sheet switches to the pending
/// screen. Outcomes go back through `NativeCheckoutCallbacks`:
/// `.paymentPending` once `performCheckout` completes, completion on
/// `fulfillment_complete` (backend status `completed`), and every stop or
/// failure as the SDK's normal `.failed` state.
@MainActor
final class StripeCheckoutModel: ObservableObject, NativeCheckoutSession {
    enum Phase: Equatable, CaseIterable { case loading, applePay, working, finished }
    @Published private(set) var phase: Phase = .loading {
        // The checkout sheet follows the phase, as it does for MoonPay (see
        // `presentation(for:autoApplePay:)`): hidden while Stripe prepares and
        // while a returning Link user signs in before Apple Pay, compact with
        // only the Apple Pay button when it has to be tapped, and hidden
        // again after Apple Pay until the SDK shows the outcome.
        didSet { if phase != oldValue { reportPresentation() } }
    }

    /// Opening Apple Pay without a tap, as the SDK does for MoonPay and
    /// Coinbase: once Stripe is ready the session presents Apple Pay itself
    /// while the checkout sheet stays hidden.
    enum AutoApplePay: Equatable {
        /// Will open Apple Pay as soon as the view has a presenter.
        case pending
        /// Apple Pay was requested; the checkout sheet stays hidden.
        case presenting
        /// Not (or no longer) automatic: the compact sheet shows the button.
        case off
    }
    @Published private(set) var autoApplePay: AutoApplePay = .pending {
        didSet { if autoApplePay != oldValue { reportPresentation() } }
    }
    /// Set when the app resigned active while Apple Pay was requested: the
    /// native sheet appeared, so a cancel came from the customer.
    private var applePaySheetShown = false
    private var applePaySheetObserver: NSObjectProtocol?
    private var autoApplePayTimeout: Task<Void, Never>?
    /// How long the session waits for the view to start Apple Pay before it
    /// shows the button instead (MoonPay waits as long for its auto-tap).
    static let autoApplePayTimeoutNanoseconds: UInt64 = 5_000_000_000

    /// Where the Link sign-in before Apple Pay stands. Only the setting
    /// `before_payment` starts it, and only when the held Link sign-in was
    /// not reused (`decideLinkStep`, `beforeApplePay`).
    enum EarlySignIn: Equatable {
        /// Not asked for (`after_payment`, or no setting from an older
        /// backend), not needed (the held Link sign-in was reused, so Link is
        /// already done), or given up because the view never gave a
        /// presenter. Apple Pay comes next.
        case off
        /// Stripe is ready and the pass starts as soon as the view gives a
        /// presenter (`presenterReady`); without one it falls back to `.off`
        /// after `autoApplePayTimeoutNanoseconds`.
        case waitingForPresenter
        /// The pass is running: Link lookup, then for a returning user
        /// `start_auth`, Link's code screen and `complete_auth`.
        case running
        /// The pass is over and Apple Pay comes next: the user signed in, or
        /// has no Link account yet and registers after Apple Pay as before.
        case applePayNext
        /// The customer closed or denied Link's screen: the checkout ended
        /// quietly and Apple Pay is never shown.
        case cancelled
    }
    private var earlySignIn: EarlySignIn = .off
    private var signInPresenterTimeout: Task<Void, Never>?
    /// The controller inside the checkout sheet that Link's sign-in presents
    /// from before Apple Pay (the Apple Pay step gets its own from the view).
    /// Weak: the sheet owns it.
    private weak var signInPresenter: UIViewController?
    /// The user is signed in to Link before Apple Pay, by either route: the
    /// backend accepted this app session's held sign-in (`reuseLinkSession`,
    /// `reuse_auth`), or a returning user signed in first
    /// (`signInBeforeApplePay`, `complete_auth` done and not stopped). The
    /// one flag both routes set: `collectApplePay` then goes from Apple Pay
    /// straight to `drive`, with no Link lookup, registration, `start_auth`,
    /// authorize or `complete_auth`, and Apple Pay does not ask for the
    /// phone (`LinkSessionRules.requestsPhone`).
    private var linkAuthorized = false
    /// The Link lookup made before Apple Pay (`signInBeforeApplePay`), reused
    /// by `collectApplePay` so a new user under `before_payment` is not
    /// looked up twice. nil in the original order, where the only lookup is
    /// after Apple Pay. A user who registered elsewhere in between is still
    /// handled there by the `linkAccountAlreadyExists` recovery.
    private var knownHasLinkAccount: Bool?

    /// A closing session reports nothing: `close()` moves to `.finished` while
    /// the SDK is still in `.rendering`, and reporting that would reveal the
    /// hidden checkout sheet just as a cancel resets the checkout.
    private func reportPresentation() {
        guard !closed else { return }
        sdk?.setNativePresentation(Self.presentation(for: phase, autoApplePay: autoApplePay), from: self)
    }

    /// Pure mapping, kept separate so it is unit tested.
    ///
    /// Everything after Apple Pay (Link, KYC, payment, delivery) runs with the
    /// checkout sheet hidden, as MoonPay's does: the app's own page stays on
    /// screen with Buy spinning, Stripe presents its own screens (the Link
    /// code, 3-D Secure) over it, and the SDK reveals the sheet only for the
    /// outcome (pending, completed or failed). No filler screen in between.
    /// The Link sign-in before Apple Pay (a returning user under
    /// `before_payment`) runs in `.loading`, so it is hidden the same way.
    static func presentation(for phase: Phase, autoApplePay: AutoApplePay = .off) -> NativeCheckoutPresentation {
        switch phase {
        case .loading, .working, .finished: return .loading
        case .applePay: return autoApplePay == .off ? .applePayButton : .autoApplePay
        }
    }
    @Published private(set) var message = "Preparing Apple Pay…"
    @Published private(set) var busy = false
    /// Latest backend response; starts as the finalize response.
    @Published private(set) var snapshot: V2CheckoutSnapshot
    /// Weak: the client owns this session (`OnramperClient.nativeSession`),
    /// so a strong reference back would keep both alive after the app drops
    /// the client. Without a client every further step ends quietly.
    private weak var sdk: OnramperClient?
    /// Checkout id, approved quote, finalize response, wallet and network.
    let context: NativeCheckoutContext

    /// True when the backend handed out a sandbox publishable key, so the
    /// payment step can label itself; live keys show no sandbox badge.
    var isSandbox: Bool { snapshot.providerContext?.publishableKey?.hasPrefix("pk_test_") ?? false }
    private let merchantIdentifier: String
    private let merchantName: String
    private let callbacks: NativeCheckoutCallbacks
    private var api: CheckoutAPI {
        get throws {
            guard let sdk else { throw CancellationError() }
            return CheckoutAPI(sdk: sdk)
        }
    }
    /// This checkout's Stripe coordinator: the one held for the app process
    /// (`StripeLinkSession`), reused or newly created in `prepareApplePay`.
    private var coordinator: CryptoOnrampCoordinator?
    private var operation: Task<Void, Never>?
    /// Wallet contact from Apple Pay, used for L0 KYC in `drive`.
    private var contact: KycInfo?
    private var newLinkAccount = false
    private var submittedL0 = false
    /// Apple Pay was collected a second time because Stripe reported a KYC
    /// region change at `createCryptoPaymentToken` (see `recollectApplePay`).
    /// Set before the sheet opens, so that recovery runs at most once per
    /// checkout, even if the backend asks for `register_wallet_and_prepare_payment`
    /// again afterwards.
    private var recollectedApplePay = false
    /// `performCheckout` was invoked: a charge may exist from here on, so the
    /// backend checkout is never cancelled and the SDK never supersedes the
    /// session on dismissal (`NativeCheckoutSession.paymentStarted`).
    @Published private(set) var paymentStarted = false
    /// The payment was accepted and `.paymentPending` reported, so a later
    /// polling error is not a failure.
    @Published private(set) var reportedPending = false
    private var closed = false
    private var started = false
    /// Current step name, for `step.*` diagnostics only.
    private var step = "start"
    /// When the current step began, for `durationMs` in verbose step details.
    private var stepStartedAt = ContinuousClock.now
    // Stripe documents that its shared state supports one coordinator at a
    // time. Weak, so a session dropped without `close()` (its client was
    // deallocated) cannot block every later Stripe checkout in the process.
    // The coordinator itself outlives the session (`StripeLinkSession`); the
    // lease keeps two checkouts from using it at once.
    private static weak var leaseHolder: StripeCheckoutModel?

    /// How long `drive` follows the checkout. Ten minutes covers Stripe's KYC
    /// review and crypto delivery on a normal sandbox run. Past it, a checkout
    /// whose payment was accepted stays `.paymentPending`; one that never
    /// reached payment fails with `timedOut`.
    static let driveTimeout: TimeInterval = 10 * 60

    /// Whether any checkout currently holds the single-coordinator lease.
    static var isLeaseHeld: Bool { leaseHolder != nil }

    /// Closing the sheet now would abandon a payment whose outcome is not
    /// known yet; the view disables closing meanwhile.
    var paymentInFlight: Bool { paymentStarted && !reportedPending && !closed }

    /// `StripeCheckout.linkSignInOverride` as it was when this checkout
    /// started (nil: follow the partner setting from the backend).
    private let linkSignInOverride: String?

    init(sdk: OnramperClient, context: NativeCheckoutContext, merchantIdentifier: String,
         merchantName: String, callbacks: NativeCheckoutCallbacks, linkSignInOverride: String? = nil) {
        self.sdk = sdk
        self.context = context
        self.merchantIdentifier = merchantIdentifier
        self.merchantName = merchantName
        self.callbacks = callbacks
        self.linkSignInOverride = linkSignInOverride
        snapshot = context.finalized
    }

    // MARK: NativeCheckoutSession

    /// Called by the SDK once it is in `.rendering` for this checkout.
    func start() {
        guard !started else { return }
        started = true
        // Taken synchronously so `close()` can release it synchronously too.
        guard Self.leaseHolder == nil else {
            run { throw CheckoutFailure.busy }
            return
        }
        // A sign-out drop that waited for an open checkout runs now if that
        // checkout went away without `close()` (it was deallocated).
        StripeLinkSession.checkoutEnded()
        Self.leaseHolder = self
        // One operation, sheet hidden (`.loading`) throughout: set up Stripe,
        // try to reuse this app session's Link sign-in and, when that is not
        // possible, decide the Link sign-in order (`decideLinkStep`). What
        // comes next starts from `then`, once this run is over and `busy` is
        // clear: the Apple Pay step, or the early Link sign-in pass (which
        // also waits for the view's presenter). `autoCollectApplePayIfPending`
        // and `run` refuse to start anything while a step is busy, so Apple
        // Pay is never presented from inside `run`.
        run {
            try await self.prepareApplePay()
            try await self.decideLinkStep()
        } then: {
            self.startAfterPreparation()
        }
    }

    /// The user closed the checkout sheet, or a new checkout superseded this one.
    func cancel() { close() }

    func makeView() -> AnyView { AnyView(StripeCheckoutView(model: self)) }

    // MARK: Steps

    /// Checks the finalize response and sets up Stripe. The Apple Pay support
    /// and merchant id checks come first in every order, so a device that
    /// cannot pay never sees Link. Then the coordinator held for this app
    /// process is reused when it belongs to the same Stripe key and email;
    /// otherwise the old one is dropped (and logged out) and a new one is
    /// created and held. Ends with Stripe ready and the sheet still hidden;
    /// `decideLinkStep` says what comes next.
    private func prepareApplePay() async throws {
        let finalized = snapshot
        begin("prepareApplePay", finalized)
        try checkSnapshot(finalized)
        guard finalized.nextAction == "collect_payment_and_register",
              // Test or live: the partner's Stripe keys decide the mode (the
              // backend checks the secret and publishable key are the same
              // mode). Only require a Stripe publishable key here.
              let key = finalized.providerContext?.publishableKey, key.hasPrefix("pk_"),
              // The verified OnramperID email is the Link identity, and with
              // the key it decides whether the held coordinator may be reused.
              let email = finalized.providerContext?.email, !email.isEmpty,
              merchantIdentifier.hasPrefix("merchant.") else { throw CheckoutFailure.configuration }
        // PassKit's canMakePayments is synchronous and Stripe documents stalls
        // of seconds to minutes, so query it off the main actor to keep the UI
        // responsive. (Stripe caches the answer per process.)
        let supportsApplePay = await Task.detached(priority: .userInitiated) { StripeAPI.deviceSupportsApplePay() }.value
        detail("prepareApplePay", "checked", [
            "publishableKey": key,
            "keyMode": key.hasPrefix("pk_live_") ? "live" : (key.hasPrefix("pk_test_") ? "test" : "unknown"),
            "merchantIdentifier": merchantIdentifier,
            "merchantName": merchantName,
            "deviceSupportsApplePay": String(supportsApplePay),
        ])
        try Task.checkCancellation()
        guard supportsApplePay else { throw CheckoutFailure.applePayUnavailable }
        guard let theme = sdk?.configuration.theme else { throw CancellationError() }
        var appearance = LinkAppearance()
        switch theme {
        case .system: appearance.style = .automatic
        case .light: appearance.style = .alwaysLight
        case .dark: appearance.style = .alwaysDark
        }
        // A closed checkout's operation (which may still be inside a call on
        // the held coordinator) and any late `logOut` must be over before this
        // checkout touches Stripe's shared state.
        await StripeLinkSession.cleanupFinished()
        try Task.checkCancellation()
        let owner = LinkSessionOwner(publishableKey: key, email: email)
        if let held = StripeLinkSession.held, LinkSessionRules.canReuse(held: held.owner, for: owner) {
            // Same Stripe account and same OnramperID email: keep the Link
            // sign-in (if any) of an earlier checkout in this app process.
            // The appearance is the one it was created with.
            coordinator = held.coordinator
            detail("prepareApplePay", "coordinatorReused", ["hasLinkSignIn": String(held.customerId != nil)])
        } else {
            // Nothing held, or it belongs to another key or email: log the old
            // coordinator out and wait for it, so its `logOut` (which clears
            // Stripe's process-wide Link account) cannot land on the new one.
            StripeLinkSession.drop()
            await StripeLinkSession.cleanupFinished()
            try Task.checkCancellation()
            begin("createCoordinator", finalized)
            detail("createCoordinator", "request", [
                "publishableKey": key, "countryHint": "US", "appearanceStyle": "\(appearance.style)",
            ])
            let client = STPAPIClient(publishableKey: key)
            let created = try await CryptoOnrampCoordinator.create(apiClient: client, appearance: appearance, countryHint: "US")
            // Held at once, before the cancellation check, so a coordinator is
            // never created and then lost without being tracked.
            StripeLinkSession.hold(created, for: owner)
            coordinator = created
            detail("createCoordinator", "ok")
            try Task.checkCancellation()
        }
        // Stripe is ready: the provider has loaded, in every order. Reported
        // here rather than when Apple Pay is entered, so a Link reuse or a
        // returning user's sign-in before Apple Pay (or closing Link's
        // screen) does not delay or hide it.
        await callbacks.onEvent(.providerReady, "stripe_apple_pay_ready")
    }

    /// What happens before Apple Pay, once the Link reuse attempt is known.
    /// Steps 2 and 3 of the order in this type's header.
    enum BeforeApplePay: Equatable {
        /// The held Link sign-in was reused (`reuse_auth` accepted): Link is
        /// done, so Apple Pay (no phone), then `drive`. No `link.order`: no
        /// order was decided.
        case reusedSignIn
        /// `before_payment`: look the email up and, for a returning Link
        /// user, sign in before Apple Pay (`signInBeforeApplePay`). Its
        /// `link.order` is logged after the lookup.
        case signInPass
        /// The original order: Apple Pay first, Link after it
        /// (`link.order` `reason=notRequested`).
        case applePayFirst
    }

    /// Pure decision, kept separate so it is unit tested: what follows a
    /// `reuse_auth` answer. `LinkSessionRules.afterReuse` decides stop,
    /// accepted or fallback; an accepted reuse then gets the same check as a
    /// sign-in before Apple Pay (`afterSignIn`), so a next step `drive` cannot
    /// run fails before Face ID instead of after it.
    static func afterReuse(status: String, reason: String?, nextAction: String?) -> LinkSessionRules.AfterReuse {
        let decision = LinkSessionRules.afterReuse(status: status, reason: reason)
        guard decision == .applePay else { return decision }
        return afterSignIn(status: status, nextAction: nextAction) == .unsupported ? .unsupported : .applePay
    }

    /// Pure decision, kept separate so it is unit tested. An accepted reuse
    /// wins whatever the setting: the user is already signed in, so there is
    /// nothing to order. Without one (nothing held, `link_reuse_unavailable`
    /// or any reuse error) the Link sign-in setting applies, exactly as
    /// `wantsSignInFirst` reads it.
    static func beforeApplePay(reused: Bool, setting: String?) -> BeforeApplePay {
        if reused { return .reusedSignIn }
        return wantsSignInFirst(setting: setting) ? .signInPass : .applePayFirst
    }

    /// Decides how Link happens in this checkout, still inside the first
    /// `run` with the sheet hidden: reuse the held Link sign-in if possible
    /// (`reuseLinkSession`, which throws when the backend stopped the
    /// checkout), else apply the Link sign-in order. Leaves `earlySignIn` at
    /// `.waitingForPresenter` when the early pass comes next; everything else
    /// goes to the Apple Pay step (`startAfterPreparation`).
    private func decideLinkStep() async throws {
        let reused = try await reuseLinkSession()
        switch Self.beforeApplePay(reused: reused, setting: linkSignInSetting) {
        case .reusedSignIn:
            // `linkAuthorized` is set; Apple Pay asks for no phone.
            break
        case .signInPass:
            earlySignIn = .waitingForPresenter
        case .applePayFirst:
            logLinkOrder(.applePayFirst, reason: "notRequested")
        }
    }

    /// The step after preparation, started once the first `run` is over and
    /// `busy` is clear: the early Link sign-in pass when `decideLinkStep`
    /// asked for it (it starts as soon as the view gives a presenter), else
    /// the Apple Pay step.
    private func startAfterPreparation() {
        if earlySignIn == .waitingForPresenter {
            startEarlySignInIfReady()
        } else {
            enterApplePay()
        }
    }

    /// Before Apple Pay, for a returning purchase in this app process: asks
    /// the backend to reuse the Link authorization the held coordinator
    /// signed in with (`reuse_auth` with its crypto customer id). Returns
    /// true when the reuse was accepted.
    ///
    /// - Accepted (`verify` / `ready`): the Link step is done
    ///   (`linkAuthorized`), so after Apple Pay the checkout goes straight to
    ///   `drive` and the user sees no Link screen.
    /// - Stopped: ends the checkout like any backend stop; Apple Pay is
    ///   never shown.
    /// - `link_reuse_unavailable`, any other answer, or any error (an older
    ///   backend rejects the unknown action with a 4xx): false, and the Link
    ///   sign-in order decides what follows. Never a checkout failure.
    ///
    /// Logs `link.session` once per checkout that gets here.
    private func reuseLinkSession() async throws -> Bool {
        guard let coordinator, let held = StripeLinkSession.held, held.coordinator === coordinator,
              let customerId = held.customerId else {
            sdk?.v2LogLinkSession(.notHeld)
            return false
        }
        let value = snapshot
        begin("reuseAuth", value)
        let response: V2CheckoutSnapshot
        do {
            response = try await api.advance(value.headlessCheckoutId, action: LinkSessionRules.reuseAction, customerId: customerId)
        } catch let error where !(error is CancellationError) {
            // Closed meanwhile: end quietly instead of carrying on to Apple Pay.
            try Task.checkCancellation()
            sdk?.v2LogStepRecovered("reuseAuth", reason: "reuseAuthFailed", error: error)
            detail("reuseAuth", "recovered", Self.errorDetail(error))
            // The backend may have applied the reuse even though its answer was
            // lost (a timeout, a dropped connection). Its status then shows the
            // checkout past `collect_payment`, where `start_auth` would be
            // refused, so decide on that status instead. Unreadable: fall back.
            guard let current = try? await api.status(value.headlessCheckoutId) else {
                try Task.checkCancellation()
                sdk?.v2LogLinkSession(.unavailable)
                return false
            }
            try Task.checkCancellation()
            detail("reuseAuth", "statusAfterError", Self.describe(current))
            response = current
        }
        try Task.checkCancellation()
        detail("reuseAuth", "ok", Self.describe(response))
        switch Self.afterReuse(status: response.status, reason: response.reason, nextAction: response.nextAction) {
        case .unsupported:
            // Accepted, but `drive` could not run the next step after Apple
            // Pay: fail now, as the sign-in before Apple Pay does.
            snapshot = response
            sdk?.v2LogLinkSession(.reused)
            throw CheckoutFailure.unavailable
        case .stop:
            // The backend accepted the request and stopped the checkout (for
            // example the eligibility check `complete_auth` also runs). The
            // stopped snapshot also tells `close()` not to cancel it again.
            snapshot = response
            sdk?.v2LogLinkSession(.reused)
            throw CheckoutFailure.stopped(reason: response.reason, restart: response.nextAction == "restart")
        case .applePay:
            snapshot = response
            linkAuthorized = true
            sdk?.v2LogLinkSession(.reused)
            return true
        case .fallback:
            // The finalize snapshot stays: the Link sign-in order starts from
            // `collect_payment` exactly as without this step.
            sdk?.v2LogStepRecovered("reuseAuth", reason: response.reason ?? "notReused")
            sdk?.v2LogLinkSession(.unavailable)
            return false
        }
    }

    /// The one way into the Apple Pay step, in every order: after an accepted
    /// reuse or the original-order decision (`startAfterPreparation`), after
    /// the early sign-in pass, or when that pass gave up waiting for a
    /// presenter. The session then opens Apple Pay itself once the view has a
    /// presenter (`autoCollectApplePayIfPending`, triggered by the view on
    /// this phase change), or shows the button after the timeout.
    ///
    /// Synchronous and always called with `busy` clear (from a `run`'s
    /// `then`, or from the presenter timeout, which runs outside any step),
    /// so nothing suspends between the phase change and the view's reaction,
    /// and that reaction is never refused as busy.
    private func enterApplePay() {
        phase = .applePay
        startAutoApplePayTimeout()
    }

    // MARK: Link sign-in before Apple Pay

    /// The Link sign-in order this checkout follows: the demo/QA override if
    /// the app set one, else the partner setting from the finalize response
    /// (read once, before anything else advances).
    private var linkSignInSetting: String? {
        Self.linkSignIn(override: linkSignInOverride, partner: context.finalized.providerContext?.linkSignIn)
    }

    /// Pure decision, kept separate so it is unit tested: an override set by
    /// the app (`StripeCheckout.linkSignInOverride`) wins over the partner
    /// setting; without one the partner setting (or nil from an older
    /// backend) applies.
    static func linkSignIn(override: String?, partner: String?) -> String? {
        override ?? partner
    }

    /// Logs the order this checkout runs in (`link.order`). Called at most
    /// once per checkout, only where the order is actually decided:
    /// `decideLinkStep` (not asked for), `signInBeforeApplePay` (after the
    /// lookup) or the presenter timeout (fallback). Never after an accepted
    /// reuse of the held Link sign-in: Link is done then, so no order was
    /// decided (`link.session` `outcome=reused` says what happened).
    private func logLinkOrder(_ order: LinkOrder, reason: String) {
        sdk?.v2LogLinkOrder(order.rawValue, setting: linkSignInSetting,
                            source: linkSignInOverride == nil ? "partner" : "override", reason: reason)
    }

    /// Called by the view once it can present (its controller inside the
    /// checkout sheet appeared). Keeps the controller for Link's sign-in and
    /// starts the pass if Stripe is already ready. A no-op in the original
    /// order and once the pass started.
    func presenterReady(_ presenter: UIViewController) {
        signInPresenter = presenter
        startEarlySignInIfReady()
    }

    /// Starts the sign-in pass once Stripe is ready (`decideLinkStep` left
    /// `.waitingForPresenter`) and the view gave a presenter. Called from
    /// both sides, whichever comes last; with Stripe ready but no presenter
    /// yet it starts the wait for one.
    private func startEarlySignInIfReady() {
        guard earlySignIn == .waitingForPresenter, !busy, !closed else { return }
        guard let presenter = signInPresenter else {
            startSignInPresenterTimeout()
            return
        }
        signInPresenterTimeout?.cancel()
        signInPresenterTimeout = nil
        earlySignIn = .running
        message = "Connecting with Link…"
        // Its own `run`, so `busy` is clear again before the Apple Pay step
        // begins: `autoCollectApplePayIfPending` and `run` refuse to start
        // anything while a step is busy. Hence also no Apple Pay from inside
        // this pass or `drive`.
        run { try await self.signInBeforeApplePay(from: presenter) } then: {
            guard self.earlySignIn == .applePayNext else { return }
            self.enterApplePay()
        }
    }

    /// Link's screen needs a presenter. If the view never gives one, fall back
    /// to the original order after the same 5 s the automatic Apple Pay open
    /// waits: from there it is the `after_payment` flow, except that the
    /// Apple Pay button shows right away instead of Apple Pay opening by
    /// itself (that would need the same missing presenter).
    private func startSignInPresenterTimeout() {
        guard signInPresenterTimeout == nil else { return }
        signInPresenterTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: Self.autoApplePayTimeoutNanoseconds) } catch { return }
            guard let self, self.earlySignIn == .waitingForPresenter, !self.closed else { return }
            self.signInPresenterTimeout = nil
            self.earlySignIn = .off
            self.logLinkOrder(.applePayFirst, reason: "noPresenter")
            // The 5 s wait for a presenter is already over, so do not wait
            // another 5 s for the automatic Apple Pay open (it needs the same
            // presenter): show the Apple Pay button right away.
            self.autoApplePay = .off
            self.enterApplePay()
        }
    }

    /// The Link sign-in pass before Apple Pay (`before_payment`), with the
    /// checkout sheet hidden (`.loading`); Link presents its code screen over
    /// it, as it does after Apple Pay.
    ///
    /// Looks the verified OnramperID email up in Link first. A new user has
    /// nothing to sign in to yet (registering needs Apple Pay's name and
    /// phone), so they keep the original order. A returning user signs in,
    /// and Stripe's eligibility answer at `complete_auth` decides whether
    /// Apple Pay is shown at all (`afterSignIn`).
    private func signInBeforeApplePay(from presenter: UIViewController) async throws {
        let value = snapshot
        // The email from the finalize response (checked in `prepareApplePay`),
        // as `collectApplePay` reads it: the Link identity never changes
        // within a checkout.
        guard let coordinator, let email = context.finalized.providerContext?.email else { throw CheckoutFailure.configuration }
        try checkSnapshot(value)
        begin("lookupLinkAccount", value)
        detail("lookupLinkAccount", "request", ["email": email])
        let hasLinkAccount = try await coordinator.hasLinkAccount(with: email)
        detail("lookupLinkAccount", "ok", ["hasLinkAccount": String(hasLinkAccount)])
        try Task.checkCancellation()
        knownHasLinkAccount = hasLinkAccount
        let order = Self.linkOrder(setting: linkSignInSetting, hasLinkAccount: hasLinkAccount)
        logLinkOrder(order, reason: hasLinkAccount ? "returningLinkUser" : "newLinkUser")
        guard order == .signInFirst else {
            // `collectApplePay` looks the email up again after Apple Pay and
            // registers the user there, unchanged from the original order.
            earlySignIn = .applePayNext
            return
        }
        guard try await authorizeLink(value, from: presenter) else {
            // Closing or denying Link's screen ends the checkout quietly, like
            // closing the Apple Pay sheet the session opened itself: the hidden
            // checkout sheet closes and Buy is offered again. Not a failure:
            // nothing was charged and the customer chose to stop.
            earlySignIn = .cancelled
            sdk?.v2LogStepRecovered("authorize", reason: "linkCancelled")
            await callbacks.onEvent(.paymentCancelled, "stripe_link_cancelled")
            return
        }
        try Task.checkCancellation()
        switch Self.afterSignIn(status: snapshot.status, nextAction: snapshot.nextAction) {
        case .unsupported:
            // A next step `drive` could not run after Apple Pay (a backend
            // change, or an unmapped verify state): fail now, as `drive`
            // would, but before Face ID instead of after it.
            throw CheckoutFailure.unavailable
        case .end:
            // Stripe's eligibility check stopped the checkout (for example
            // `additional_kyc_required` or `unsupported_region`). It ends as
            // every backend stop does, with the reason on the SDK's failed
            // screen, before Face ID instead of after it.
            throw CheckoutFailure.stopped(reason: snapshot.reason, restart: snapshot.nextAction == "restart")
        case .applePay:
            linkAuthorized = true
            earlySignIn = .applePayNext
        }
    }

    /// Link sign-in for an email that has a Link account, in either order:
    /// `start_auth`, Link's own code screen (`authorize`, presented from
    /// `presenter`), then `complete_auth`, whose response (`snapshot`)
    /// carries Stripe's eligibility answer. Returns false when the customer
    /// closed or denied Link's screen; each caller decides what that means.
    /// Every successful sign-in is recorded on the held coordinator
    /// (`StripeLinkSession.recordSignIn`) for the next checkout's reuse.
    private func authorizeLink(_ value: V2CheckoutSnapshot, from presenter: UIViewController) async throws -> Bool {
        guard let coordinator else { throw CheckoutFailure.configuration }
        begin("startAuth", value)
        let auth = try await api.advance(value.headlessCheckoutId, action: "start_auth")
        try Task.checkCancellation()
        snapshot = auth
        detail("startAuth", "ok", Self.describe(auth))
        guard auth.nextAction == "authorize", let authId = auth.providerContext?.authIntentId else { throw CheckoutFailure.unavailable }
        begin("authorize", auth)
        detail("authorize", "request", ["linkAuthIntentId": authId])
        let authorization = try await coordinator.authorize(linkAuthIntentId: authId, from: presenter)
        detail("authorize", "result", ["result": String(reflecting: authorization)]) // log-guard: allow verbose-only Stripe detail
        try Task.checkCancellation()
        guard case .consented(let customerId) = authorization else { return false }
        begin("completeAuth", auth)
        snapshot = try await api.advance(value.headlessCheckoutId, action: "complete_auth", customerId: customerId)
        detail("completeAuth", "ok", Self.describe(snapshot))
        // The Link sign-in now lives on the held coordinator, whichever order
        // ran (early pass or after Apple Pay; for a new user, registration
        // then this authorize). Recording the customer lets the next checkout
        // in this app process ask for `reuse_auth` instead of signing in
        // again. Recorded even when `complete_auth` stopped the checkout: the
        // Link sign-in itself succeeded, and the backend answers eligibility
        // again at the next `reuse_auth`.
        StripeLinkSession.recordSignIn(customerId: customerId, on: coordinator)
        return true
    }

    /// Which comes first in a checkout.
    enum LinkOrder: String, Equatable {
        /// Link sign-in, then Apple Pay: a returning Link user under
        /// `before_payment`.
        case signInFirst
        /// Apple Pay, then Link (lookup, registration of a new user,
        /// sign-in): the original order.
        case applePayFirst
    }

    /// The `linkSignIn` value that asks for sign-in before Apple Pay.
    static let signInBeforePayment = "before_payment"

    /// Pure decision, kept separate so it is unit tested. Only an explicit
    /// `before_payment` AND an existing Link account sign in first. A new
    /// user registers after Apple Pay (it supplies the name and phone);
    /// `after_payment`, no value (an older backend) or an unknown value keep
    /// the original order.
    static func linkOrder(setting: String?, hasLinkAccount: Bool) -> LinkOrder {
        wantsSignInFirst(setting: setting) && hasLinkAccount ? .signInFirst : .applePayFirst
    }

    /// Whether the backend setting asks for a returning user's sign-in
    /// before Apple Pay, before anything is known about the user. Gates the
    /// Link lookup before Apple Pay; `linkOrder` then decides per user.
    static func wantsSignInFirst(setting: String?) -> Bool {
        setting == signInBeforePayment
    }

    /// What follows a completed Link sign-in before Apple Pay.
    enum AfterSignIn: Equatable {
        /// The backend stopped the checkout at `complete_auth`: end it.
        /// Apple Pay is never shown.
        case end
        /// The backend asked for a next step `drive` cannot run: fail
        /// before Apple Pay rather than after Face ID.
        case unsupported
        /// The Apple Pay step, then `drive` (L0 KYC if needed, payment).
        case applePay
    }

    /// Pure decision, kept separate so it is unit tested: a checkout stopped
    /// at `complete_auth` never shows Apple Pay, and neither does one whose
    /// next step `drive` would reject (`driveStep` is the same mapping
    /// `drive` uses after Apple Pay). `verify` (L0 KYC or a pending
    /// verification) and `ready` go on to Apple Pay, then `drive`.
    static func afterSignIn(status: String, nextAction: String?) -> AfterSignIn {
        if status == "stopped" { return .end }
        let step = driveStep(nextAction: nextAction, paymentStarted: false, submittedL0: false)
        return step == .unsupported ? .unsupported : .applePay
    }

    // MARK: Opening Apple Pay automatically

    /// Called by the view once it can present (and again when the phase
    /// changes): opens Apple Pay without a tap, once per session.
    func autoCollectApplePayIfPending(from presenter: UIViewController) {
        guard autoApplePay == .pending, phase == .applePay, !busy, !closed else { return }
        autoApplePayTimeout?.cancel()
        autoApplePayTimeout = nil
        observeApplePaySheet()
        autoApplePay = .presenting
        detail("collectApplePay", "autoPresent")
        collectApplePay(from: presenter)
    }

    /// The view never started Apple Pay (no presenter): show the button.
    private func startAutoApplePayTimeout() {
        autoApplePayTimeout?.cancel()
        autoApplePayTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: Self.autoApplePayTimeoutNanoseconds) } catch { return }
            guard let self, self.autoApplePay == .pending, self.phase == .applePay else { return }
            self.sdk?.v2LogStepRecovered("collectApplePay", reason: "autoApplePayNotStarted")
            self.autoApplePay = .off
        }
    }

    /// Starts watching for an Apple Pay sheet the session opens without a tap
    /// (the automatic open, or the re-collection after a KYC region change).
    /// Apple Pay's sheet resigns the app's active state; that is the only
    /// signal that it actually appeared (MoonPay's auto-tap uses the same).
    private func observeApplePaySheet() {
        stopObservingApplePaySheet()
        applePaySheetShown = false
        applePaySheetObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applePaySheetShown = true }
        }
    }

    private func stopObservingApplePaySheet() {
        if let applePaySheetObserver { NotificationCenter.default.removeObserver(applePaySheetObserver) }
        applePaySheetObserver = nil
    }

    /// The customer closed an Apple Pay sheet the session opened by itself:
    /// the checkout ends quietly, as MoonPay's does. The SDK treats
    /// `.paymentCancelled` as a dismissal (`onCheckoutCancelled`), which
    /// closes this session (backend cancel; the Link sign-in stays held for
    /// the next checkout, see `close()`), closes the hidden checkout sheet and
    /// offers Buy again.
    private func endAsApplePayCancel(step: String) async {
        sdk?.v2LogStepRecovered(step, reason: "applePayCancelled")
        await callbacks.onEvent(.paymentCancelled, "stripe_apple_pay_cancelled")
    }

    /// Apple Pay ended without a payment method. A tap on the button just
    /// stays on the button. After the automatic open: a sheet the customer
    /// saw and closed ends the checkout quietly, as MoonPay's does (the hidden
    /// checkout sheet closes and Buy is offered again); a sheet that never
    /// appeared (for example no usable card) shows the button instead.
    private func applePayEndedWithoutPayment() async {
        guard autoApplePay == .presenting else { return }
        stopObservingApplePaySheet()
        if applePaySheetShown {
            detail("collectApplePay", "cancelledAfterAutoPresent")
            await endAsApplePayCancel(step: "collectApplePay")
        } else {
            sdk?.v2LogStepRecovered("collectApplePay", reason: "autoApplePayNotShown")
            autoApplePay = .off
        }
    }

    /// Apple Pay request for the quoted total.
    ///
    /// Contact fields: billing name + postal address feed Stripe's L0 KYC
    /// (`attachKYCInfo`); the phone (shipping contact, no shipping address) is
    /// only needed to register a NEW Link user, so `requestPhone` is false
    /// whenever the user is signed in to Link before Apple Pay: the held
    /// sign-in was reused, or a returning user signed in first
    /// (`LinkSessionRules.requestsPhone(linkAuthorized:)`, the one phone
    /// rule). It is true in the original order, where the Link lookup only
    /// happens after Apple Pay, and false for the re-collection after a KYC
    /// region change (Link is done by then). No email: the BFF-provided
    /// OnramperID email is the canonical identity, and a second, possibly
    /// different, Wallet email would only invite a mismatch.
    ///
    /// The summary item is the quoted total the user approved, shown as a
    /// `.final` amount so Apple Pay displays it (a `.pending` item, as in
    /// Stripe's example, shows only "Amount Pending"). Stripe still charges
    /// later, in `performCheckout`, against the onramp session; for a debit
    /// card that is this total. Whether the charge can be held to it exactly
    /// is an open question with Stripe.
    static func paymentRequest(merchantIdentifier: String, merchantName: String, total: Decimal,
                               requestPhone: Bool) -> PKPaymentRequest {
        let request = StripeAPI.paymentRequest(withMerchantIdentifier: merchantIdentifier, country: "US", currency: "USD")
        request.requiredBillingContactFields = [.name, .postalAddress]
        request.requiredShippingContactFields = requestPhone ? [.phoneNumber] : []
        request.paymentSummaryItems = [PKPaymentSummaryItem(label: "\(merchantName) (through Stripe)",
                                                            amount: NSDecimalNumber(decimal: total), type: .final)]
        return request
    }

    /// The quoted total Apple Pay shows (see `paymentRequest`), parsed the
    /// same way for the first collection and the re-collection after a KYC
    /// region change. Nil when the backend sent no positive decimal amount.
    private static func quotedTotal(_ value: V2CheckoutSnapshot) -> Decimal? {
        guard let total = Decimal(string: value.quote.sourceTotalAmount, locale: Locale(identifier: "en_US_POSIX")),
              total > 0 else { return nil }
        return total
    }

    /// Apple Pay, then straight on to Link: no review step in between.
    ///
    /// The Buy tap already accepted Link's terms (recorded at finalize), and
    /// the Apple Pay sheet itself shows the Wallet name, address and phone the
    /// user authorizes, so a new Link user is registered as soon as the
    /// contact passes `linkSetup`. An incomplete contact still stops with
    /// `CheckoutFailure.contactDetails` before anything is sent to Link.
    ///
    /// When the user is already signed in to Link (`linkAuthorized`: the held
    /// sign-in was reused, or a returning user signed in before Apple Pay),
    /// Apple Pay is followed directly by `drive`: no Link lookup,
    /// registration, `start_auth`, authorize or `complete_auth`, so no Link
    /// screen. `drive` still submits L0 with the Apple Pay contact when the
    /// backend asks, registers the wallet, creates the payment token (which
    /// needs only the crypto customer id the coordinator already holds) and
    /// pays.
    func collectApplePay(from presenter: UIViewController) {
        run {
            let value = self.snapshot
            guard let coordinator = self.coordinator,
                  let total = Self.quotedTotal(value),
                  // From the finalize response (checked in `prepareApplePay`):
                  // after a reused Link sign-in `snapshot` is the `reuse_auth`
                  // response, which need not repeat the email.
                  let email = self.context.finalized.providerContext?.email else {
                throw CheckoutFailure.configuration
            }
            try self.checkSnapshot(value)
            self.begin("collectApplePay", value)
            let requestPhone = LinkSessionRules.requestsPhone(linkAuthorized: self.linkAuthorized)
            let request = Self.paymentRequest(merchantIdentifier: self.merchantIdentifier, merchantName: self.merchantName,
                                              total: total, requestPhone: requestPhone)
            self.detail("collectApplePay", "request", [
                "merchantIdentifier": request.merchantIdentifier, "countryCode": request.countryCode,
                "currencyCode": request.currencyCode, "total": "\(total)", "email": email,
                "summaryItems": request.paymentSummaryItems.map { "\($0.label)=\($0.amount) (\($0.type.rawValue))" }.joined(separator: "; "),
            ])
            let result = try await coordinator.collectPaymentMethod(type: .applePay(paymentRequest: request), from: presenter)
            self.detail("collectApplePay", "result", ["result": String(reflecting: result)]) // log-guard: allow verbose-only Stripe detail
            try Task.checkCancellation()
            // Dismissing the sheet is not a failure: after a tap the user stays
            // on the Apple Pay step and can try again without a new quote; after
            // the automatic open see `applePayEndedWithoutPayment`.
            guard case .completed(_, let info) = result else {
                await self.applePayEndedWithoutPayment()
                return
            }
            self.stopObservingApplePaySheet()
            await self.callbacks.onEvent(.paymentAuthorized, "stripe_apple_pay_authorized")
            try Task.checkCancellation()
            guard let info else { throw CheckoutFailure.contactDetails }
            if self.linkAuthorized {
                // Link was done before Apple Pay (`reuse_auth` or the early
                // sign-in pass): no lookup, registration, `start_auth`, Link
                // screen or `complete_auth` again. The contact only feeds L0
                // KYC: name and US address, no phone (matching the request).
                guard Self.hasCompleteContact(info, requirePhone: requestPhone) else { throw CheckoutFailure.contactDetails }
                self.contact = info
                self.phase = .working
                self.message = "Preparing payment…"
                try await self.drive(from: presenter)
                return
            }
            // Look the email up BEFORE validating the contact: whether a phone
            // is required depends on the answer (new users only). Under
            // `before_payment` it was already looked up before Apple Pay.
            let hasLinkAccount: Bool
            if let known = self.knownHasLinkAccount {
                hasLinkAccount = known
                self.detail("lookupLinkAccount", "reused", ["hasLinkAccount": String(known)])
            } else {
                self.begin("lookupLinkAccount", value)
                self.detail("lookupLinkAccount", "request", ["email": email])
                hasLinkAccount = try await coordinator.hasLinkAccount(with: email)
                self.detail("lookupLinkAccount", "ok", ["hasLinkAccount": String(hasLinkAccount)])
                try Task.checkCancellation()
            }
            let setup = try Self.linkSetup(for: info, hasLinkAccount: hasLinkAccount)
            self.contact = info
            self.phase = .working
            self.message = "Connecting with Link…"
            if case .registerNewUser(let fullName, let phone) = setup {
                self.newLinkAccount = true
                self.begin("registerLinkUser", value)
                do {
                    // The verified OID email is the account identity; the
                    // Wallet supplies only the name and phone.
                    self.detail("registerLinkUser", "request",
                                ["email": email, "fullName": fullName, "phone": phone, "country": "US"])
                    let customerId = try await coordinator.registerLinkUser(email: email, fullName: fullName, phone: phone, country: "US")
                    self.detail("registerLinkUser", "ok", ["cryptoCustomerId": customerId])
                } catch CryptoOnrampCoordinator.Error.linkAccountAlreadyExists {
                    // The account exists after all (created between lookup and
                    // registration, or by an earlier attempt). Same verified
                    // email, so authorize it like a returning user.
                    self.sdk?.v2LogStepRecovered("registerLinkUser", reason: "linkAccountAlreadyExists")
                    self.newLinkAccount = false
                }
                try Task.checkCancellation()
            }
            // Closing Link's screen here, after Apple Pay, stays a failure as
            // before ("Checkout cancelled."); only the sign-in before Apple
            // Pay ends quietly. `authorizeLink` records the sign-in on the
            // held coordinator for the next checkout.
            guard try await self.authorizeLink(value, from: presenter) else { throw CheckoutFailure.cancelled }
            try await self.drive(from: presenter)
        }
    }

    /// What happens with Link once Apple Pay returns the Wallet contact.
    enum LinkSetup: Equatable {
        /// No Link account for the OID email: register one with these values.
        case registerNewUser(fullName: String, phone: String)
        /// The email already has a Link account: go straight to authorize
        /// (or, when the user signed in before Apple Pay, straight to `drive`).
        case existingUser
    }

    /// Pure decision after Apple Pay, kept separate so it is unit tested.
    /// Throws `contactDetails` when the Wallet contact cannot complete this
    /// flow (see `hasCompleteContact`); a new user otherwise goes directly to
    /// registration, since tapping Buy was the consent. A phone is required
    /// for a new user only, the same rule `paymentRequest(requestPhone:)`
    /// follows. A user signed in before Apple Pay (not asked for a phone)
    /// never gets here: `collectApplePay` checks that contact with
    /// `hasCompleteContact` and no phone.
    static func linkSetup(for info: KycInfo, hasLinkAccount: Bool) throws -> LinkSetup {
        guard hasCompleteContact(info, requirePhone: !hasLinkAccount) else { throw CheckoutFailure.contactDetails }
        if hasLinkAccount { return .existingUser }
        guard let firstName = info.firstName, let lastName = info.lastName, let phone = info.phone else {
            throw CheckoutFailure.contactDetails
        }
        return .registerNewUser(fullName: "\(firstName) \(lastName)", phone: phone)
    }

    /// Whether Apple Pay returned what this flow needs: a US name and full
    /// postal address for L0 KYC always; an E.164 phone only when it will
    /// register a new Link user (`registerLinkUser` requires one). Email is
    /// never required: the OnramperID email is used instead.
    static func hasCompleteContact(_ info: KycInfo, requirePhone: Bool) -> Bool {
        let required = [info.firstName, info.lastName,
                        info.address?.line1, info.address?.city, info.address?.state, info.address?.postalCode]
        guard required.allSatisfy({ !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }),
              info.address?.country?.uppercased() == "US" else { return false }
        guard requirePhone else { return true }
        return info.phone?.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil
    }

    /// What `drive` does for a backend `nextAction`.
    enum DriveStep: Equatable { case submitL0, wait, prepare, performCheckout, unsupported }

    /// Pure mapping, kept separate so the payment-safety rules are unit tested.
    static func driveStep(nextAction: String?, paymentStarted: Bool, submittedL0: Bool) -> DriveStep {
        switch nextAction {
        // L0 is submitted once; until Stripe finishes reviewing it the backend
        // may keep asking, which only means "not verified yet".
        case "submit_l0": return submittedL0 ? .wait : .submitL0
        case "wait": return .wait
        case "register_wallet_and_prepare_payment": return .prepare
        // After `performCheckout` returns, the backend only learns the new
        // session state on a later read, so `perform_checkout` can still come
        // back. That means "not settled yet", never "pay again": exactly one
        // SDK checkout per payment.
        case "perform_checkout": return paymentStarted ? .wait : .performCheckout
        default: return .unsupported
        }
    }

    private func drive(from presenter: UIViewController) async throws {
        let deadline = Date().addingTimeInterval(Self.driveTimeout)
        while true {
            let value = snapshot
            try Task.checkCancellation()
            if value.status == "completed" {
                begin("completed", value)
                phase = .finished
                await callbacks.onComplete()
                close()
                return
            }
            if value.status == "stopped" { throw CheckoutFailure.stopped(reason: value.reason, restart: value.nextAction == "restart") }
            if value.status == "processing" {
                message = "Payment received. Waiting for crypto delivery…"
                // The backend saw the payment succeed. Normally reported right
                // after `performCheckout`; this covers a payment confirmed only
                // through status (see the `.performCheckout` step below).
                if paymentStarted && !reportedPending {
                    reportedPending = true
                    await callbacks.onEvent(.paymentPending, "stripe_payment_processing")
                }
            }
            if Date() >= deadline { throw CheckoutFailure.timedOut }
            switch Self.driveStep(nextAction: value.nextAction, paymentStarted: paymentStarted, submittedL0: submittedL0) {
            case .submitL0:
                guard let coordinator, let info = contact else { throw CheckoutFailure.unavailable }
                message = "Verifying your details…"
                begin("submitL0", value)
                // No DOB, SSN, document collection, or automatic L1/L2 upgrade.
                submittedL0 = true
                let kyc = KycInfo(firstName: info.firstName, lastName: info.lastName,
                                  idNumber: nil, address: info.address, dateOfBirth: nil)
                detail("submitL0", "request", ["kycInfo": String(reflecting: kyc)]) // log-guard: allow verbose-only Stripe detail
                try await coordinator.attachKYCInfo(info: kyc)
                detail("submitL0", "ok")
                try await pauseAndRead(value)
            case .wait:
                try await pauseAndRead(value)
            case .prepare:
                guard let coordinator else { throw CheckoutFailure.configuration }
                try checkSnapshot(value)
                message = "Preparing payment…"
                guard let network = CryptoNetwork(rawValue: context.destinationNetwork) else { throw CheckoutFailure.configuration }
                begin("registerWallet", value)
                do {
                    detail("registerWallet", "request",
                           ["walletAddress": context.walletAddress, "network": network.rawValue])
                    try await coordinator.registerWalletAddress(walletAddress: context.walletAddress, network: network)
                    detail("registerWallet", "ok")
                } catch let error where !newLinkAccount && !(error is CancellationError) {
                    // A returning Link user has usually registered this wallet
                    // before, and Stripe can reject the duplicate. Keep going:
                    // the backend creates the onramp session for this wallet at
                    // prepare_payment, so a genuinely unusable wallet still stops
                    // the checkout there, before any payment. This includes a
                    // reused sign-in whose Link session is gone
                    // (`StripeLinkSession.isSessionGone`): the payment token
                    // needs only the crypto customer id, so the purchase can
                    // still complete and the held coordinator is kept.
                    let details = Self.providerDetails(error)
                    sdk?.v2LogStepRecovered("registerWallet", reason: "returningUser", error: error,
                                           providerCode: details.code, providerRequestId: details.requestId,
                                           providerMessage: details.message)
                    detail("registerWallet", "recovered", Self.errorDetail(error))
                }
                try Task.checkCancellation()
                begin("createPaymentToken", value)
                let token: String
                do {
                    token = try await coordinator.createCryptoPaymentToken()
                } catch let error where Self.recollectsApplePay(after: error, alreadyRecollected: recollectedApplePay,
                                                                 cancelled: Task.isCancelled) {
                    // Apple Pay ran before the Link customer existed, so Stripe
                    // bound the payment method to the region it assumed then
                    // (our `countryHint`); authentication resolved a different
                    // KYC region and the method cannot be used. Stripe's KYC
                    // guide (Platform Pay with L0 KYC, step 7): collect Apple
                    // Pay again with the same authenticated coordinator and
                    // retry the token. Once only: the flag is set before the
                    // sheet opens, and a failure of the single retry below is
                    // reported like any other token failure. A checkout whose
                    // Link sign-in was reused (`reuse_auth`) collected Apple
                    // Pay with the customer already known, so this is expected
                    // only in the Apple Pay first path; the recovery is the
                    // same either way.
                    recollectedApplePay = true
                    let details = Self.providerDetails(error)
                    sdk?.v2LogStepRecovered("createPaymentToken", reason: "kycRegionChanged", error: error,
                                            providerCode: details.code, providerRequestId: details.requestId,
                                            providerMessage: details.message)
                    detail("createPaymentToken", "recovered", Self.errorDetail(error))
                    // The customer closed the sheet: the checkout already ended
                    // as a cancel, so stop driving it.
                    guard try await recollectApplePay(with: coordinator, from: presenter, value) else { return }
                    try Task.checkCancellation()
                    begin("createPaymentToken", value)
                    token = try await coordinator.createCryptoPaymentToken()
                }
                detail("createPaymentToken", "ok", ["paymentToken": token])
                try Task.checkCancellation()
                begin("preparePayment", value)
                snapshot = try await api.advance(value.headlessCheckoutId, action: "prepare_payment", paymentToken: token)
                detail("preparePayment", "ok", Self.describe(snapshot))
            case .performCheckout:
                // Only one SDK invocation. Its distinct callbacks can continue a
                // challenge; an uncertain response never starts another payment.
                guard let coordinator, let sessionId = value.providerContext?.sessionId else { throw CheckoutFailure.unavailable }
                try checkSnapshot(value)
                paymentStarted = true
                message = "Processing payment…"
                begin("performCheckout", value)
                detail("performCheckout", "request", ["onrampSessionId": sessionId])
                do {
                    let result = try await coordinator.performCheckout(onrampSessionId: sessionId,
                        authenticationContext: PresenterContext(presenter)) { [self] callbackSession in
                        try Task.checkCancellation()
                        detail("performCheckout", "callback", ["callbackSessionId": callbackSession])
                        guard callbackSession == sessionId else { throw CheckoutFailure.configuration }
                        let next = try await api.advance(value.headlessCheckoutId, action: "checkout")
                        detail("performCheckout", "checkoutResponse", Self.describe(next))
                        snapshot = next
                        if next.status == "stopped" { throw CheckoutFailure.stopped(reason: next.reason, restart: next.nextAction == "restart") }
                        guard let secret = next.providerContext?.clientSecret else { throw CheckoutFailure.unavailable }
                        return secret
                    }
                    detail("performCheckout", "result", ["result": String(reflecting: result)]) // log-guard: allow verbose-only Stripe detail
                    try Task.checkCancellation()
                    guard case .completed = result else { throw CheckoutFailure.cancelled }
                } catch let error where Self.resolvesByStatus(error) {
                    // A Stripe or network error after the payment call: the
                    // charge may or may not exist, and the backend knows which.
                    // Follow its status instead of reporting an unconfirmed
                    // payment at once (the old "Check status", automated).
                    // `paymentStarted` turns `perform_checkout` into a wait, so
                    // this never pays again; a stop, `processing`/`completed`
                    // or the drive timeout settles it.
                    let details = Self.providerDetails(error)
                    sdk?.v2LogStepRecovered("performCheckout", reason: "resolvingByStatus", error: error,
                                            providerCode: details.code, providerRequestId: details.requestId,
                                            providerMessage: details.message)
                    detail("performCheckout", "recovered", Self.errorDetail(error))
                    try await pauseAndRead(value)
                    continue
                }
                message = "Payment submitted. Checking crypto delivery…"
                // The payment was accepted: the SDK moves to `.paymentPending`
                // (its pending screen replaces this view) while this loop keeps
                // following delivery to `completed`.
                reportedPending = true
                await callbacks.onEvent(.paymentPending, "stripe_payment_submitted")
                try await pauseAndRead(value)
            case .unsupported:
                throw CheckoutFailure.unavailable
            }
        }
    }

    // MARK: KYC region change

    /// Stripe's stable code for `PaymentMethodKYCRegionChangedError`.
    static let kycRegionChangedCode = "payment_method_kyc_region_changed"

    /// Whether `createCryptoPaymentToken` failed because the Apple Pay payment
    /// method was collected for a different KYC region than the customer's.
    ///
    /// StripeCryptoOnramp 26.15.1 throws `PaymentMethodKYCRegionChangedError`
    /// when Apple Pay was collected before the crypto customer id existed and
    /// the publishable key resolved for the authenticated customer differs
    /// from the one the payment method was created with. Matched by type, and
    /// by its stable `code` so a rename of the type in a later release still
    /// matches (the type cannot be built outside Stripe, so the tests use the
    /// code).
    static func isKYCRegionChanged(_ error: Error) -> Bool {
        if error is PaymentMethodKYCRegionChangedError { return true }
        return (error as? StripeCryptoOnrampError)?.code == kycRegionChangedCode
    }

    /// Pure decision, kept separate so the "at most once" rule is unit tested:
    /// re-collect Apple Pay only for a KYC region change, and only if this
    /// checkout has not done so already. Any other error, or a second region
    /// change, fails the step as before. Never once the checkout was closed
    /// (`cancelled`): Stripe's token call does not stop on cancellation, so
    /// its region change can arrive after `close()`, and Apple Pay must not
    /// open again over the app (the next checkout would also wait for that
    /// sheet in `StripeLinkSession.cleanupFinished`).
    static func recollectsApplePay(after error: Error, alreadyRecollected: Bool, cancelled: Bool) -> Bool {
        !cancelled && !alreadyRecollected && isKYCRegionChanged(error)
    }

    /// The contact kept for L0 KYC after Apple Pay was collected again.
    ///
    /// The first collection's contact already passed `hasCompleteContact`
    /// (and normally L0 was submitted with it before payment preparation), so
    /// it stays unless the new Wallet contact is complete too. No phone is
    /// required here: it is only needed to register a new Link user, which
    /// already happened.
    static func l0Contact(previous: KycInfo?, recollected: KycInfo?) -> KycInfo? {
        guard let recollected, hasCompleteContact(recollected, requirePhone: false) else { return previous }
        return recollected
    }

    /// Presents Apple Pay a second time on the same coordinator, after
    /// `createCryptoPaymentToken` reported a KYC region change. The customer
    /// is authenticated by now, so Stripe binds the new payment method to the
    /// resolved region and the retried token does not hit the same check.
    ///
    /// Runs inside `drive`, not through `collectApplePay`: that goes through
    /// `run`, whose `busy` guard refuses a second operation while this one is
    /// still running. Same builder as the first collection
    /// (`paymentRequest`), so the sheet shows the same approved total, but
    /// without the phone: `drive` only runs once the Link step is done (signed
    /// in, registered or reused), so no registration can follow and the
    /// phone rule (`LinkSessionRules.requestsPhone`) says no. The checkout
    /// sheet stays hidden (phase `.working`); Apple Pay presents over the app
    /// as it did the first time.
    ///
    /// Returns true when a new payment method was selected. Returns false when
    /// the customer closed the sheet: the checkout then ends the same way a
    /// closed automatic Apple Pay ends (`endAsApplePayCancel`). Throws when
    /// Stripe fails, or when Apple Pay ended without its sheet ever appearing
    /// (there is no Apple Pay button to fall back to at this point, and ending
    /// quietly would give the customer no reason).
    private func recollectApplePay(with coordinator: CryptoOnrampCoordinator, from presenter: UIViewController,
                                   _ value: V2CheckoutSnapshot) async throws -> Bool {
        guard let total = Self.quotedTotal(value) else { throw CheckoutFailure.configuration }
        begin("recollectApplePay", value)
        let request = Self.paymentRequest(merchantIdentifier: merchantIdentifier, merchantName: merchantName, total: total,
                                          requestPhone: LinkSessionRules.requestsPhone(linkAuthorized: true))
        detail("recollectApplePay", "request", [
            "merchantIdentifier": request.merchantIdentifier, "total": "\(total)",
        ])
        observeApplePaySheet()
        defer { stopObservingApplePaySheet() }
        let result = try await coordinator.collectPaymentMethod(type: .applePay(paymentRequest: request), from: presenter)
        detail("recollectApplePay", "result", ["result": String(reflecting: result)]) // log-guard: allow verbose-only Stripe detail
        try Task.checkCancellation()
        guard case .completed(_, let info) = result else {
            // Stripe keeps the previous (rejected) selection on cancel, so a
            // token retry would only fail again: end here instead.
            guard applePaySheetShown else { throw CheckoutFailure.applePayUnavailable }
            detail("recollectApplePay", "cancelled")
            await endAsApplePayCancel(step: "recollectApplePay")
            return false
        }
        // No second `.paymentAuthorized`: the checkout reported its Apple Pay
        // authorization once already, and integrators and telemetry count one
        // per checkout.
        contact = Self.l0Contact(previous: contact, recollected: info)
        return true
    }

    private func checkSnapshot(_ value: V2CheckoutSnapshot) throws {
        if value.status == "stopped" { throw CheckoutFailure.stopped(reason: value.reason, restart: value.nextAction == "restart") }
        guard context.approvedQuote.matches(value.quote) else { throw CheckoutFailure.changedPrice }
    }

    private func pauseAndRead(_ value: V2CheckoutSnapshot) async throws {
        try await Task.sleep(nanoseconds: UInt64(min(max(value.retryAfterMs ?? 2000, 1000), 5000)) * 1_000_000)
        snapshot = try await api.status(value.headlessCheckoutId)
        detail("status", "polled", Self.describe(snapshot))
    }

    /// Whether a `performCheckout` failure is settled by following the
    /// backend status. Not for this module's own failures (a backend stop, a
    /// declined authentication, a contract problem), which already say what
    /// happened, nor for cancellation.
    static func resolvesByStatus(_ error: Error) -> Bool {
        !(error is CheckoutFailure) && !(error is CancellationError)
    }

    private func begin(_ step: String, _ value: V2CheckoutSnapshot? = nil) {
        self.step = step
        stepStartedAt = .now
        sdk?.v2LogStepStarted(step, status: value?.status, nextAction: value?.nextAction)
        if let value { detail(step, "started", Self.describe(value)) }
    }

    // MARK: Diagnostics

    /// Unsanitized step inputs, results and errors, for internal verbose builds
    /// only (`Verbose.Stripe` / `stripe.step`). Values are built only when the
    /// build is verbose; normal builds keep the sanitized `step.*` events.
    private func detail(_ step: String, _ outcome: String, _ values: @autoclosure () -> [String: String] = [:]) {
        guard let sdk, sdk.v2VerboseLogging else { return }
        var context = values()
        context["durationMs"] = String(Int((ContinuousClock.now - stepStartedAt) / .milliseconds(1)))
        sdk.v2LogProviderDetail(step, outcome: outcome, context)
    }

    /// Every field of a backend response, including its provider context.
    static func describe(_ value: V2CheckoutSnapshot) -> [String: String] {
        ["status": value.status, "nextAction": value.nextAction ?? "<none>", "reason": value.reason ?? "<none>",
         "snapshot": String(reflecting: value)] // log-guard: allow verbose-only Stripe detail
    }

    /// Everything an error carries, down its underlying-error chain: type,
    /// domain, code, the full value, every userInfo entry and, for Stripe's
    /// rich crypto errors, code, messages, doc URL and request id.
    static func errorDetail(_ error: Error) -> [String: String] {
        var out: [String: String] = [:]
        var current: Error? = error
        var depth = 0
        while let item = current, depth < 6 {
            let prefix = depth == 0 ? "error" : "underlying\(depth)"
            let ns = item as NSError
            out["\(prefix).type"] = "\(type(of: item))"
            out["\(prefix).domain"] = ns.domain
            out["\(prefix).code"] = String(ns.code)
            out["\(prefix).value"] = String(reflecting: item) // log-guard: allow verbose-only Stripe detail
            for (key, value) in ns.userInfo where key != NSUnderlyingErrorKey {
                out["\(prefix).userInfo.\(key)"] = String(reflecting: value) // log-guard: allow verbose-only Stripe detail
            }
            if let rich = item as? StripeCryptoOnrampError {
                out["\(prefix).stripeCode"] = rich.code
                out["\(prefix).userMessage"] = rich.userMessage
                out["\(prefix).developerMessage"] = rich.developerMessage
                out["\(prefix).docURL"] = rich.docURL?.absoluteString ?? "<none>"
            }
            if let requestId = (item as? StripeCryptoOnrampAPIError)?.requestID {
                out["\(prefix).requestID"] = requestId
            }
            current = (item as? StripeCryptoOnrampError)?.underlyingError ?? (ns.userInfo[NSUnderlyingErrorKey] as? Error)
            depth += 1
        }
        return out
    }

    /// Stripe's error code, request id and developer-facing message, from its
    /// rich crypto errors or, for plain API errors (`com.stripe.lib`), from
    /// the NSError userInfo Stripe fills in. The message goes through the
    /// SDK's sanitizer in normal builds.
    static func providerDetails(_ error: Error) -> (code: String?, requestId: String?, message: String?) {
        let info = (error as NSError).userInfo
        let rich = error as? StripeCryptoOnrampError
        let code = rich?.code ?? info["com.stripe.lib:StripeErrorCodeKey"] as? String
        let requestId = (error as? StripeCryptoOnrampAPIError)?.requestID ?? info["com.stripe.lib:StripeRequestIDKey"] as? String
        var message = rich?.developerMessage ?? info["com.stripe.lib:ErrorMessageKey"] as? String
        // Plain API errors: add type, parameter and HTTP status when present,
        // since the message alone rarely says which request failed.
        if rich == nil {
            let extras = [("type", info["com.stripe.lib:StripeErrorTypeKey"]),
                          ("param", info["com.stripe.lib:ErrorParameterKey"]),
                          ("http", info["com.stripe.lib:HTTPStatusCodeKey"])]
                .compactMap { name, value in value.map { "\(name)=\($0)" } }
            if !extras.isEmpty { message = ([message].compactMap { $0 } + extras).joined(separator: " ") }
        }
        return (code, requestId, message)
    }

    /// Runs one step at a time: `busy` while it runs, so no other step (and no
    /// automatic Apple Pay open) can start meanwhile. `then` runs once the
    /// step finished without an error and `busy` is clear again, so it can
    /// start the next step: the Link sign-in pass once Stripe is ready, or
    /// the Apple Pay step after that pass.
    private func run(_ action: @escaping @MainActor () async throws -> Void,
                     then next: (@MainActor () async -> Void)? = nil) {
        guard !busy, !closed else { return }
        busy = true
        operation = Task { @MainActor in
            guard await perform(action), !closed else { return }
            await next?()
        }
    }

    /// Runs `action` with `busy` set (cleared on return); true when it
    /// finished without an error.
    private func perform(_ action: @MainActor () async throws -> Void) async -> Bool {
        defer { busy = false }
        do {
            try await action()
            return true
        } catch {
            // `close()` cancels the operation and sets `closed` first, so
            // its cancellation ends quietly here. Any other error, a stray
            // `CancellationError` included, is reported: a silent end would
            // leave the spinner up and the lease held.
            guard !closed else { return false }
            await report(error)
            return false
        }
    }

    /// What the SDK is told when a step fails.
    enum Outcome: Equatable {
        /// The payment was already accepted (`.paymentPending` reported):
        /// stop following it and leave the SDK pending.
        case keepPending
        /// `OnramperError.providerFailed`: the outcome is not a confirmed
        /// payment failure (nothing charged yet, or not known).
        case failed(String)
        /// `OnramperError.paymentFailed`: the backend stopped a checkout
        /// whose payment had started.
        case paymentFailed(String)
    }

    /// Pure mapping, kept separate so the payment-safety rules are unit tested.
    static func outcome(for error: Error, paymentStarted: Bool, reportedPending: Bool) -> Outcome {
        if let failure = error as? CheckoutFailure, case .stopped = failure {
            // The backend's decision is final, before or after payment.
            return paymentStarted ? .paymentFailed(failure.userMessage) : .failed(failure.userMessage)
        }
        // An accepted payment is still settling: a polling error or the drive
        // timeout says nothing about it, and the pending screen is accurate.
        if reportedPending { return .keepPending }
        // `performCheckout` ran but did not confirm: the charge may have
        // happened, so never suggest the payment simply failed.
        if paymentStarted { return .failed(CheckoutFailure.unconfirmedPaymentMessage) }
        if let failure = error as? CheckoutFailure { return .failed(failure.userMessage) }
        if let failure = error as? OnramperError { return .failed(failure.userMessage) }
        return .failed("Checkout could not continue. Please try again.")
    }

    /// Logs the failed step, reports the outcome to the SDK, then ends the session.
    ///
    /// A failure because the Link session is gone (`isSessionGone`, e.g. L0
    /// KYC on a reused sign-in whose consumer session expired) also drops the
    /// held coordinator, so the next Buy signs in to Link again instead of
    /// failing the same way. The user sees the generic retry message.
    private func report(_ error: Error) async {
        let goneCoordinator = StripeLinkSession.isSessionGone(error) ? coordinator : nil
        let details = Self.providerDetails(error)
        var reason: String?
        if case .stopped(let stopReason, _) = error as? CheckoutFailure { reason = stopReason }
        sdk?.v2LogStepFailed(step, error: error, reason: reason,
                            providerCode: details.code, providerRequestId: details.requestId,
                            providerMessage: details.message)
        detail(step, "failed", Self.errorDetail(error))
        phase = .finished
        switch Self.outcome(for: error, paymentStarted: paymentStarted, reportedPending: reportedPending) {
        case .keepPending: break
        case .failed(let message): await callbacks.onFailed(message)
        case .paymentFailed(let message): await callbacks.onPaymentFailed(message)
        }
        close()
        // After `close()`, so the `logOut` is queued behind this session's
        // own cleanup (which waits for this operation to finish).
        if let goneCoordinator { StripeLinkSession.drop(goneCoordinator) }
    }

    /// Ends the session: on cancel from the SDK, or by itself once the
    /// checkout completed or failed. Idempotent.
    func close() {
        guard !closed else { return }
        autoApplePayTimeout?.cancel()
        signInPresenterTimeout?.cancel()
        stopObservingApplePaySheet()
        detail(step, "close", ["phase": "\(phase)", "status": snapshot.status,
                               "paymentStarted": String(paymentStarted), "reportedPending": String(reportedPending),
                               "earlySignIn": "\(earlySignIn)", "linkAuthorized": String(linkAuthorized)])
        closed = true
        phase = .finished
        operation?.cancel()
        // Release the single-coordinator lease now, not after cleanup: cleanup
        // awaits the cancelled operation plus a network call, and a user who
        // closes and immediately retries must not be told a checkout is still
        // running. The next session still waits for this cleanup before it
        // uses the held coordinator (`StripeLinkSession.cleanupFinished`), so
        // two operations never share it.
        let releasedLease = Self.leaseHolder === self
        if releasedLease { Self.leaseHolder = nil }
        // No Link `logOut` here: the coordinator stays held for the next
        // checkout in this app process, so its Link sign-in is reused instead
        // of asked for again. It is logged out only when it is dropped
        // (another key or email, OnramperID sign-out, a dead Link session).
        // Queued behind any earlier cleanup.
        StripeLinkSession.afterCleanup { [self] in
            await operation?.value
            // Free the backend checkout unless a payment may exist or the
            // backend already ended it.
            if !paymentStarted, !["intent", "stopped", "completed"].contains(snapshot.status) {
                _ = try? await api.advance(snapshot.headlessCheckoutId, action: "cancel")
            }
            coordinator = nil
            contact = nil
        }
        // After this checkout's cleanup was queued, so a sign-out drop that
        // waited for it logs out only once its operation is over.
        if releasedLease { StripeLinkSession.checkoutEnded() }
    }
}

private final class PresenterContext: NSObject, STPAuthenticationContext {
    let presenter: UIViewController
    init(_ presenter: UIViewController) { self.presenter = presenter }
    func authenticationPresentingViewController() -> UIViewController { presenter }
}
#endif
