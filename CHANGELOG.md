# Changelog

All notable changes to OnramperSDK are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

_Nothing yet._

## [1.6.0]

### Changed

- **The Stripe checkout is now an opt-in product, `OnramperStripe`.** The
  `OnramperSDK` product is the binary alone again, with no third-party
  dependencies: apps that don't use the Stripe checkout no longer build or
  ship Stripe's iOS SDK. Apps that do must add the `OnramperStripe` product
  to their target (it brings `stripe-ios-spm`, still pinned to exactly
  `26.15.1`); linking it next to `OnramperSDK` is fine, both use the same
  binary. **Migration for apps using the Stripe checkout from 1.5.0:** add
  `.product(name: "OnramperStripe", package: "onramper-ios")`; without it,
  `import OnramperStripe` no longer compiles. No code changes.
- **Returning Link users sign in to Link before Apple Pay.** A checkout that
  Stripe stops (for example for identity checks or region) now ends before
  Face ID instead of after it. New Link users still get Apple Pay first,
  because creating a Link account needs the Wallet name and phone. This is
  the default; Onramper can switch a partner back to Apple Pay first for
  everyone. Until Onramper's backend supports the setting, Apple Pay comes
  first for everyone, as in 1.5.0.
- The `finalize.finished` log record of a Stripe checkout now carries
  `transactionId`, `checkoutId` and `ramp`, like other checkouts.

### Added

- **Link sign-in kept for the app session.** After the first Stripe purchase,
  later purchases by the same OnramperID user in the same app process show no
  Link screen. The sign-in is kept in memory only: after an app relaunch the
  next purchase signs in to Link again. `reset()` keeps it; `signOut()` logs
  the user out of Link. A different OnramperID email or Stripe account starts
  a fresh Link sign-in.
- **Clear message for a declined card.** When the card issuer declines the
  Apple Pay card, the checkout fails with `OnramperError.paymentFailed` and
  the message "Your card was declined. No payment was made. Try again with
  another card." instead of waiting for up to 10 minutes.
- `StripeCheckout.linkSignInOverride` (`.beforePayment` / `.afterPayment`)
  lets demo and QA builds force either Link sign-in order. Production apps
  leave it `nil` to follow Onramper's setting.

### Fixed

- **Stripe checkout when Stripe resolves a different region after sign-in.**
  The checkout used to fail; it now opens Apple Pay once more so the payment
  method matches the verified region, then continues.
- **`import OnramperStripe` next to `@stripe/stripe-react-native`** no longer
  fails with "no such module 'StripeCore'".

The Link sign-in order, the Link sign-in reuse and the declined-card message
need Onramper's backend support; until it is deployed, Stripe checkouts work
as in 1.5.0. Apps not using the Stripe checkout get no changes beyond the
smaller dependency graph.

## [1.5.0]

### Added

- **Stripe checkout (experimental).** A native Stripe checkout inside the
  normal SDK flow: USD to USDC on Solana, Ethereum or Base, paid with Apple
  Pay, for customers in the US outside New York, up to 100 USD per purchase
  before fees. It is off until your app turns it on:
  1. Add the Apple Pay (merchant ID set up with Stripe) and App Attest
     capabilities. It needs a physical iPhone.
  2. `import OnramperStripe` and call
     `StripeCheckout.enable(merchantIdentifier:merchantName:)` once at app
     start.
  3. Request `onlyOnramps: ["stripe"]` in `getCheckoutRequirements`.

  The total Apple Pay will charge (fees included) is in
  `quote.providerContext["sourceTotalAmount"]`. After Buy the Apple Pay sheet
  opens on its own; first-time users then create or sign in to a Link
  account (Stripe's checkout account) and may be asked to verify their
  identity. A Stripe checkout reports `.paymentPending` once paid and then
  `.completed` when the USDC is delivered. Stripe and Onramper must set it up
  for your app first; see [Stripe checkout](README.md#stripe-checkout-experimental).

### Changed

- **New dependency: Stripe's iOS SDK.** The `OnramperSDK` product now also
  contains the `OnramperStripe` module (shipped as source) and depends on
  `stripe-ios-spm`, pinned to exactly `26.15.1`. Swift Package Manager
  downloads and builds it for every app, even one that never turns the
  Stripe checkout on, so builds take longer and apps get larger. If your app
  already depends on Stripe's iOS SDK, it must use 26.15.1.

### Fixed

- **Checkouts no longer fail after the SDK session's first refresh.** The
  SDK session is refreshed after 15 minutes; until now the refresh response
  failed to decode, which ended any checkout still running at that point.

No existing API changed, so existing call sites compile unchanged and no
code migration is required.

## [1.4.1]

### Changed

- **Smoother MoonPay Apple Pay checkout.** When MoonPay has no payment
  disclosures to show, Buy now opens the native Apple Pay sheet directly,
  without the intermediate MoonPay sheet. The checkout sheet stays invisible
  until MoonPay needs the user (for example, 3-D Secure) or there is a result
  to show, so your screen can't present its own sheet or modal meanwhile.
  Coinbase Apple Pay checkout also keeps its sheet invisible until needed.

No existing API changed, so existing call sites compile unchanged and no
migration is required.

## [1.4.0]

### Added

- **Trusted partner login.** If your backend has already verified the
  user's email, add `user: { email }` to the signed
  `POST /v2/partners/{apiKey}/client-sessions` request. On Buy, the SDK then
  signs the user in to OnramperID without the email OTP:
  - **Best case:** no login UI at all — the user goes straight to the
    payment sheet.
  - **Profile fields missing:** only the OnramperID "additional info" form
    appears. There is no OTP screen and no "Grant permission" screen.
  - If an OnramperID account already exists for that email, the user is
    signed in to it; otherwise one is created with the email marked verified.

  Send the email from your own verified user record, never from the app's
  request, and send it again from your `sessionExpirationHandler`. When
  `user` is present, the session response carries
  `trustedLogin: "bound" | "unavailable"`.

  Trusted login is **enabled per integration** on the Onramper side; until it
  is, every session reports `"unavailable"` and sign-in stays the normal OTP
  flow. It is best-effort and never blocks sign-in: on any failure the normal
  OnramperID sign-in appears, with no error to handle. No app code changes are
  needed.

  While the Buy button spins, the login sheet is already presented but
  invisible (up to ~15s). Your screen stays interactive, but it can't present
  its own sheet or modal until the login sheet appears or closes.

### Changed

- **`signOut()` also clears the OnramperID web session**, so the next sign-in
  on the device doesn't offer to continue as the previous user. It closes a
  login sheet that is open (visible or not) without reporting an error, and
  turns trusted login off for that `OnramperClient`, because its session was
  minted for the previous user. When your app's signed-in user changes, call
  `signOut()`, then create and initialize a new `OnramperClient` with a
  session minted for the new user.
- When login is needed, the Buy button spins briefly while the SDK checks for
  a trusted login, then the login sheet appears. Without trusted login enabled
  this check is quick and falls back to the normal sign-in.
- **The login sheet handles load failures.** If the OnramperID page can't
  load, the sheet shows "Couldn't load sign-in" with **Retry** and **Close**
  instead of staying blank. A page already on screen is kept if a later
  request fails, so the user doesn't lose their progress.
- If OnramperID ends sign-in with an error (for example, the user declines),
  the login sheet closes and Buy is tappable again.

### Fixed

- A stalled OnramperID sign-in now fails after 15 seconds instead of leaving
  the Buy button spinning.

No existing API changed and no enum gained cases, so existing call sites
compile unchanged and no migration is required.

## [1.3.1]

### Added

- **SDK version at runtime.** `OnramperClient.sdkVersion` returns the
  installed SDK version as plain semver (e.g. `"1.3.1"`) — handy for your
  diagnostics, analytics, or a support screen.

  ```swift
  Text("Onramper SDK \(OnramperClient.sdkVersion)")
  ```

  Use it instead of reading the framework bundle: the xcframework's
  `CFBundleShortVersionString` is not the SDK version, and under static
  linking a `Bundle(for:)` lookup returns your app's version instead.
  It is a `nonisolated static` property, so you can read it from any thread
  or actor without an `OnramperClient` instance.

No existing API changed, so no migration is required.

## [1.3.0]

### Upgrading

- **Exhaustive `switch`es need new cases.** `OnramperError`, `OnramperState`
  and `CheckoutEvent` gained cases (listed below). A `switch` without a
  `default` stops compiling until you handle them; nothing else in your
  integration needs to change.
- **Users sign in to OnramperID once more after updating.** Stored
  credentials are now kept separately per environment, and the previous
  shared entries are removed on first launch. The SDK session re-establishes
  itself silently; a user who was signed in sees the OnramperID login sheet
  again on their next checkout.

### Added

- **MoonPay Apple Pay checkout.** When MoonPay prices an Apple Pay checkout,
  the SDK runs MoonPay's checkout inside the payment sheet: guest checkout or
  MoonPay account onboarding when required, 3-D Secure verification, and
  MoonPay's required payment disclosures shown next to the Apple Pay button.
  Nothing to integrate — the checkout button handles it, and the disclosures
  can't be hidden.
- **Pending payments.** A payment that is accepted but not yet settled now
  ends in `OnramperState.paymentPending` (with `CheckoutEvent.paymentPending`)
  instead of `.completed`. The SDK shows "Payment processing" with the
  transaction id; dismissing the sheet keeps this outcome. Treat it as
  neither success nor failure and track it with `currentTransactionId`.
- **End-user error copy.** Every `OnramperError` now has `userMessage` —
  plain copy that is safe to show users — and `supportCode`, a short stable
  code that is safe to show alongside it and matches what the SDK logs.

  ```swift
  showAlert(message: error.userMessage, footnote: "Error code: \(error.supportCode)")
  ```

- New `OnramperError` cases:
  - `.paymentFailed(String)` — the provider confirmed the payment failed
    (e.g. card declined).
  - `.providerFailed(String)` — the payment surface failed without confirming
    the payment outcome. After a status error the payment may have gone
    through; `userMessage` tells the user to check before retrying.
  - `.applePayNotConfigured` — no Apple Pay card in Wallet on this device.
- New `CheckoutEvent` cases, also delivered through
  `didReceiveProviderEvent`: `paymentPending`, `challengeStarted`,
  `challengeCompleted` (3-D Secure) and `customerOnboardingRequired`
  (MoonPay guest checkout unavailable; the SDK opens MoonPay onboarding).
- **Custom log sink.** `OnramperConfiguration` accepts `logHandler`, which
  receives structured `OnramperLogRecord`s (`timestamp`, `level`, `category`,
  `event`, `context`, `message`) — for example to write a log file your
  testers can export. Compose it with `OnramperLog.systemHandler` to keep the
  Console output.
- `QuoteResponse.providerContext` (`[String: ProviderJSONValue]?`) with
  provider-specific data, and the `ProviderJSONValue` and `PaymentDisclosure`
  types. Most integrations can ignore them.

### Changed

- **Logging is structured and sanitized at every level.** Records name a
  stable category and event instead of free text, HTTP paths are logged as
  route templates and URLs as hosts only, and a final sanitizer redacts
  anything resembling a URL, email, phone number, card number or token.
  Provider error messages are kept after best-effort redaction, so treat
  exported logs as potentially containing personal data. The default remains
  `.off`.
- `errorDescription` and `debugInfo` strings are now sanitized and no longer
  contain URLs, response bodies or tokens.
- The checkout failure screen shows `userMessage` and the support code, and
  its **Try Again** button closes the sheet and starts a fresh checkout.
- The MoonPay Apple Pay sheet opens at a compact height and expands when the
  provider needs more room.

### Fixed

- Stored credentials no longer carry over between environments (e.g. a
  staging session being reused in production).

## [1.2.2]

### Fixed

- Improved the reliability of SDK session initialization and refresh in
  production. No API changes or migration are required.

## [1.2.1]

### Added

- **Onramper transaction id.** `OnramperClient` now publishes
  `currentTransactionId` — Onramper's durable identifier for the transaction.
  It is populated the moment the checkout is finalized, *before* the payment
  surface renders, and stays readable until you start another checkout or call
  `reset()`.

  ```swift
  // SwiftUI — @Published, so views re-render when it lands
  Text(sdk.currentTransactionId ?? "—")

  // Combine / UIKit
  sdk.$currentTransactionId
      .compactMap { $0 }
      .sink { transactionId in analytics.log(transactionId) }

  // Or read it directly at any point after finalize
  let transactionId = sdk.currentTransactionId
  ```

  **This is the id to store, and the one to quote to Onramper support.** It is
  also available on the finalize response as
  `onramperTransactionId` if you consume the `checkoutFinalized` event, but the
  published property is the easier place to read it.

  Note that it is distinct from the checkout id you already receive on
  `checkoutStarted` / `didStartCheckout` and `completed` /
  `didCompleteCheckout`:

  | | checkout id | `currentTransactionId` |
  |---|---|---|
  | Identifies | one checkout *attempt* | the *transaction* |
  | Lifetime | single-use; a new one is issued every time the intent is re-created, including each time the user dismisses the payment sheet | stable for the transaction |
  | Use for | correlating logs within one attempt | **support, reconciliation, status lookups** |

  A single user journey can produce several checkout ids — one per Buy tap —
  while producing at most one transaction id. If you persist one identifier,
  persist the transaction id.

  Because it is cleared by `reset()`, read it before resetting.

  Nothing else changed: no existing type, method, event, or delegate callback
  was modified, so **existing call sites compile unchanged** and no migration
  is required.

## [1.2.0]

### Added

- Client-supplied **user-field prefill**. `getCheckoutRequirements` accepts an
  optional `prefill:` carrying values you already know about the user, and the
  OnramperID sign-in and additional-info screens arrive pre-populated instead
  of blank. New public type: `OnramperUserPrefill` — `email`, `firstName`,
  `lastName`, `phoneNumber`, all optional; supply only what you know.

  ```swift
  let result = try await sdk.getCheckoutRequirements(
      request,
      prefill: OnramperUserPrefill(
          firstName: "Ada",
          lastName: "Lovelace",
          phoneNumber: "+3712345678"   // E.164
      )
  )
  ```

  Prefill is **best-effort and never blocks sign-in.** If it cannot be applied,
  the login flow opens normally without it. No error surfaces to your app, and
  there is nothing to handle.

  A prefilled phone number is always a *candidate*: the user still verifies it,
  and a number already verified on the account takes precedence.

  **Supply `email` only when you are confident** it is the address the user will
  sign in with. It identifies which account the other values belong to, so it is
  not merely another prefilled value: when it matches the account that signs in,
  the remaining values may be applied automatically; when it does not match, the
  whole prefill is dropped — which is strictly worse than omitting `email`,
  where the values are still offered to the user for confirmation.

  Prefill is enabled per integration. Talk to your Onramper representative
  before relying on it — without it enabled, sign-in simply proceeds without
  prefill.

### Changed

- `getCheckoutRequirements(_:buttonStyle:)` gains a defaulted `prefill:`
  parameter and is now `getCheckoutRequirements(_:prefill:buttonStyle:)`.
  Existing call sites compile unchanged; no migration is required.

## [1.1.1]
Minor version including security enhancements.

### Changed (breaking)
- All clients should upgrade to this version. This version includes a new security paradigm for backend communications that is required.

## [1.1.0]

> The SDK is pre-adoption, so breaking changes ship within the 1.x line.

### Changed (breaking)

- `QuoteResponse` is now success-only. `quoteId`, `ramp`, `rate`, `payout`,
  `paymentMethod`, `networkFee`, and `transactionFee` are non-optional, and the
  `errors` field (and the `QuoteError` type) have been removed. A request that
  cannot be priced now fails with `OnramperError` (e.g. `.quoteUnavailable`)
  instead of returning a partial quote with errors.
- `OnramperTransactionData.destination` is now required (previously optional).

### Added

- Phone **reverification** support. A `reverification` checkout requirement is
  now decoded and wired through the existing OnramperID flow: when a provider
  needs a recent phone verification, the SDK transitions to `.requireLogin` and
  presents the flow with `phone_reverification=true` so the user re-verifies
  their existing number. New public types: `CheckoutRequirement.reverification`,
  `ReverificationRequirement`, `ReverificationField`. `requirementSatisfied` now
  reports each requirement type the OnramperID flow resolved (rather than always
  `.userInfo`).
- `AmountLimitRequirement.amountLimitSatisfied`.
