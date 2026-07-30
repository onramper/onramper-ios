# Changelog

All notable changes to OnramperSDK are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

_Nothing yet._

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
