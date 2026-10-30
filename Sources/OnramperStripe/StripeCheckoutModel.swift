#if canImport(UIKit)
import Foundation
import PassKit
@_spi(OnramperNative) import OnramperSDK
import StripeCore
@_spi(CryptoOnrampAlpha) import StripeCryptoOnramp
@_spi(CryptoOnrampAlpha) import StripePaymentSheet
import StripePayments

import SwiftUI

/// Runs the post-finalize steps of one Stripe Embedded Components checkout as
/// the SDK's native payment session: Apple Pay -> Link (register or look up,
/// authorize) -> KYC L0 -> wallet + payment token -> `performCheckout` ->
/// status polling.
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
        // The checkout sheet follows the phase, as it does for MoonPay:
        // hidden while Stripe prepares, compact with only the Apple Pay
        // button, full height from Link onwards.
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
    private var coordinator: CryptoOnrampCoordinator?
    private var operation: Task<Void, Never>?
    /// Wallet contact from Apple Pay, used for L0 KYC in `drive`.
    private var contact: KycInfo?
    private var newLinkAccount = false
    private var submittedL0 = false
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
    private static weak var leaseHolder: StripeCheckoutModel?
    /// Cleanup (backend cancel, Link `logOut`) of the last closed session. A
    /// new session waits for it before creating its coordinator: Stripe's
    /// state is shared, so a late `logOut` must not land on the new session.
    private static var lastCleanup: Task<Void, Never>?

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

    init(sdk: OnramperClient, context: NativeCheckoutContext, merchantIdentifier: String,
         merchantName: String, callbacks: NativeCheckoutCallbacks) {
        self.sdk = sdk
        self.context = context
        self.merchantIdentifier = merchantIdentifier
        self.merchantName = merchantName
        self.callbacks = callbacks
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
        Self.leaseHolder = self
        run { try await self.prepareApplePay() }
    }

    /// The user closed the checkout sheet, or a new checkout superseded this one.
    func cancel() { close() }

    func makeView() -> AnyView { AnyView(StripeCheckoutView(model: self)) }

    // MARK: Steps

    /// Checks the finalize response and sets up Stripe, ending on the Apple
    /// Pay button (Apple Pay is presented from the user's tap on it).
    private func prepareApplePay() async throws {
        let finalized = snapshot
        begin("prepareApplePay", finalized)
        try checkSnapshot(finalized)
        guard finalized.nextAction == "collect_payment_and_register",
              // Test or live: the partner's Stripe keys decide the mode (the
              // backend checks the secret and publishable key are the same
              // mode). Only require a Stripe publishable key here.
              let key = finalized.providerContext?.publishableKey, key.hasPrefix("pk_"),
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
        // A previous session's late `logOut` must not hit this one.
        await Self.lastCleanup?.value
        try Task.checkCancellation()
        begin("createCoordinator", finalized)
        detail("createCoordinator", "request", [
            "publishableKey": key, "countryHint": "US", "appearanceStyle": "\(appearance.style)",
        ])
        let client = STPAPIClient(publishableKey: key)
        coordinator = try await CryptoOnrampCoordinator.create(apiClient: client, appearance: appearance, countryHint: "US")
        detail("createCoordinator", "ok")
        try Task.checkCancellation()
        phase = .applePay
        startAutoApplePayTimeout()
        await callbacks.onEvent(.providerReady, "stripe_apple_pay_ready")
    }

    // MARK: Opening Apple Pay automatically

    /// Called by the view once it can present (and again when the phase
    /// changes): opens Apple Pay without a tap, once per session.
    func autoCollectApplePayIfPending(from presenter: UIViewController) {
        guard autoApplePay == .pending, phase == .applePay, !busy, !closed else { return }
        autoApplePayTimeout?.cancel()
        autoApplePayTimeout = nil
        applePaySheetShown = false
        // Apple Pay's sheet resigns the app's active state; that is the only
        // signal that it actually appeared (MoonPay's auto-tap uses the same).
        applePaySheetObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applePaySheetShown = true }
        }
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

    private func stopObservingApplePaySheet() {
        if let applePaySheetObserver { NotificationCenter.default.removeObserver(applePaySheetObserver) }
        applePaySheetObserver = nil
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
            sdk?.v2LogStepRecovered("collectApplePay", reason: "applePayCancelled")
            detail("collectApplePay", "cancelledAfterAutoPresent")
            await callbacks.onEvent(.paymentCancelled, "stripe_apple_pay_cancelled")
        } else {
            sdk?.v2LogStepRecovered("collectApplePay", reason: "autoApplePayNotShown")
            autoApplePay = .off
        }
    }

    /// Apple Pay request for the quoted total.
    ///
    /// Contact fields: billing name + postal address feed Stripe's L0 KYC
    /// (`attachKYCInfo`); the phone (shipping contact, no shipping address) is
    /// only needed to register a NEW Link user. No email: the BFF-provided
    /// OnramperID email is the canonical identity, and a second, possibly
    /// different, Wallet email would only invite a mismatch.
    ///
    /// The summary item is the quoted total the user approved, shown as a
    /// `.final` amount so Apple Pay displays it (a `.pending` item, as in
    /// Stripe's example, shows only "Amount Pending"). Stripe still charges
    /// later, in `performCheckout`, against the onramp session; for a debit
    /// card that is this total. Whether the charge can be held to it exactly
    /// is an open question with Stripe.
    static func paymentRequest(merchantIdentifier: String, merchantName: String, total: Decimal) -> PKPaymentRequest {
        let request = StripeAPI.paymentRequest(withMerchantIdentifier: merchantIdentifier, country: "US", currency: "USD")
        request.requiredBillingContactFields = [.name, .postalAddress]
        request.requiredShippingContactFields = [.phoneNumber]
        request.paymentSummaryItems = [PKPaymentSummaryItem(label: "\(merchantName) (through Stripe)",
                                                            amount: NSDecimalNumber(decimal: total), type: .final)]
        return request
    }

    /// Apple Pay, then straight on to Link: no review step in between.
    ///
    /// The Buy tap already accepted Link's terms (recorded at finalize), and
    /// the Apple Pay sheet itself shows the Wallet name, address and phone the
    /// user authorizes, so a new Link user is registered as soon as the
    /// contact passes `linkSetup`. An incomplete contact still stops with
    /// `CheckoutFailure.contactDetails` before anything is sent to Link.
    func collectApplePay(from presenter: UIViewController) {
        run {
            let value = self.snapshot
            guard let coordinator = self.coordinator,
                  let total = Decimal(string: value.quote.sourceTotalAmount, locale: Locale(identifier: "en_US_POSIX")), total > 0,
                  let email = value.providerContext?.email else {
                throw CheckoutFailure.configuration
            }
            try self.checkSnapshot(value)
            self.begin("collectApplePay", value)
            let request = Self.paymentRequest(merchantIdentifier: self.merchantIdentifier, merchantName: self.merchantName, total: total)
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
            // Look the email up BEFORE validating the contact: whether a phone
            // is required depends on the answer (new users only).
            self.begin("lookupLinkAccount", value)
            self.detail("lookupLinkAccount", "request", ["email": email])
            let hasLinkAccount = try await coordinator.hasLinkAccount(with: email)
            self.detail("lookupLinkAccount", "ok", ["hasLinkAccount": String(hasLinkAccount)])
            try Task.checkCancellation()
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
            self.begin("startAuth", value)
            let auth = try await self.api.advance(value.headlessCheckoutId, action: "start_auth")
            try Task.checkCancellation()
            self.snapshot = auth
            self.detail("startAuth", "ok", Self.describe(auth))
            guard auth.nextAction == "authorize", let authId = auth.providerContext?.authIntentId else { throw CheckoutFailure.unavailable }
            self.begin("authorize", auth)
            self.detail("authorize", "request", ["linkAuthIntentId": authId])
            let authorization = try await coordinator.authorize(linkAuthIntentId: authId, from: presenter)
            self.detail("authorize", "result", ["result": String(reflecting: authorization)]) // log-guard: allow verbose-only Stripe detail
            try Task.checkCancellation()
            guard case .consented(let customerId) = authorization else { throw CheckoutFailure.cancelled }
            self.begin("completeAuth", auth)
            self.snapshot = try await self.api.advance(value.headlessCheckoutId, action: "complete_auth", customerId: customerId)
            self.detail("completeAuth", "ok", Self.describe(self.snapshot))
            try await self.drive(from: presenter)
        }
    }

    /// What happens with Link once Apple Pay returns the Wallet contact.
    enum LinkSetup: Equatable {
        /// No Link account for the OID email: register one with these values.
        case registerNewUser(fullName: String, phone: String)
        /// The email already has a Link account: go straight to authorize.
        case existingUser
    }

    /// Pure decision after Apple Pay, kept separate so it is unit tested.
    /// Throws `contactDetails` when the Wallet contact cannot complete this
    /// flow (see `hasCompleteContact`); a new user otherwise goes directly to
    /// registration, since tapping Buy was the consent.
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
                    // the checkout there, before any payment.
                    let details = Self.providerDetails(error)
                    sdk?.v2LogStepRecovered("registerWallet", reason: "returningUser", error: error,
                                           providerCode: details.code, providerRequestId: details.requestId,
                                           providerMessage: details.message)
                    detail("registerWallet", "recovered", Self.errorDetail(error))
                }
                try Task.checkCancellation()
                begin("createPaymentToken", value)
                let token = try await coordinator.createCryptoPaymentToken()
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

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy, !closed else { return }
        busy = true
        operation = Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch {
                // `close()` cancels the operation and sets `closed` first, so
                // its cancellation ends quietly here. Any other error, a stray
                // `CancellationError` included, is reported: a silent end would
                // leave the spinner up and the lease held.
                guard !closed else { return }
                await report(error)
            }
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
    private func report(_ error: Error) async {
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
    }

    /// Ends the session: on cancel from the SDK, or by itself once the
    /// checkout completed or failed. Idempotent.
    func close() {
        guard !closed else { return }
        autoApplePayTimeout?.cancel()
        stopObservingApplePaySheet()
        detail(step, "close", ["phase": "\(phase)", "status": snapshot.status,
                               "paymentStarted": String(paymentStarted), "reportedPending": String(reportedPending)])
        closed = true
        phase = .finished
        operation?.cancel()
        // Release the single-coordinator lease now, not after cleanup: cleanup
        // awaits the cancelled operation plus two network calls, and a user
        // who closes and immediately retries must not be told a checkout is
        // still running. The next session still waits for this cleanup before
        // it creates its coordinator (`lastCleanup`), so this `logOut` cannot
        // land on it.
        if Self.leaseHolder === self { Self.leaseHolder = nil }
        // Chained, so a waiter also outlasts any earlier session's cleanup.
        let previous = Self.lastCleanup
        Self.lastCleanup = Task { @MainActor in
            await previous?.value
            await operation?.value
            // Free the backend checkout unless a payment may exist or the
            // backend already ended it.
            if !paymentStarted, !["intent", "stopped", "completed"].contains(snapshot.status) {
                _ = try? await api.advance(snapshot.headlessCheckoutId, action: "cancel")
            }
            try? await coordinator?.logOut()
            coordinator = nil
            contact = nil
        }
    }
}

private final class PresenterContext: NSObject, STPAuthenticationContext {
    let presenter: UIViewController
    init(_ presenter: UIViewController) { self.presenter = presenter }
    func authenticationPresentingViewController() -> UIViewController { presenter }
}
#endif
