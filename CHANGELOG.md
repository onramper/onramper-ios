# Changelog

All notable changes to OnramperSDK are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

_Nothing yet._

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
