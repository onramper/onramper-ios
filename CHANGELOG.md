# Changelog

All notable changes to OnramperSDK are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

_Nothing yet._

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
