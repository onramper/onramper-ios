# OnramperSDK

iOS Swift SDK for integrating Onramper's crypto onramping into native mobile apps. Provides a self-contained checkout component that handles OnramperID login, Terms of Service consent, and payment rendering, sitting on top of a DPoP-bound, App Attest-aware security layer.

## Requirements

- iOS 16.0+
- Swift 5.9+
- Xcode 15+
- App Attest capability on the host app (recommended; Tier-2 fallback works without it on simulators / unsupported devices)

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/onramper/onramper-ios.git", from: "1.3.0")
]
```

…and add `OnramperSDK` to the relevant target's dependencies:

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "OnramperSDK", package: "onramper-ios"),
])
```

Or in Xcode: **File → Add Package Dependencies** and enter the repository URL.

This repository and its release assets are public, so resolving the package needs no GitHub account, personal access token, or `~/.netrc` entry.

## Quick Start

### 1. Mint a session (partner backend)

Your backend calls `POST /v2/partners/{apiKey}/client-sessions` (signed with the partner key) and receives an opaque `(sessionId, sessionToken)` pair. Hand both to the app via your own channel — the token is single-use and time-bounded, and not a credential the SDK can mint on its own.

### 2. Initialize

```swift
import OnramperSDK

let sdk = OnramperClient(configuration: .init(
    apiKey: "pk_live_...",
    clientId: "YOUR_ONRAMPER_ID_CLIENT_ID",
    environment: .production,
    logLevel: .off,                     // .info while integrating; see "Logging" below
    sessionExpirationHandler: {
        // Called when the SDK Session expires terminally (refresh token
        // rejected, attestation revoked, etc.). Mint a fresh
        // (sessionId, sessionToken) pair from your backend and return it.
        // The SDK re-runs the bootstrap and retries the in-flight request
        // silently — your user never sees an error.
        let (sessionId, sessionToken) = try await yourBackend.fetchOnramperSession()
        return SessionCredentials(sessionId: sessionId, sessionToken: sessionToken)
    }
))

try await sdk.initialize(sessionId: sessionId, sessionToken: sessionToken)
// sdk.state == .ready
```

`initialize(sessionId:sessionToken:)` runs App Attest (when supported), exchanges the session token for a DPoP-bound access/refresh token pair, and wraps the network client so every subsequent call carries the security headers automatically.

**Token refresh is fully automatic** — both tokens (SDK Session + OnramperID) refresh proactively before expiry and reactively on 401, with single-flight coalescing. You don't need to retry. The two recovery paths when a refresh ultimately fails:

- **OnramperID user-token failure** → SDK transitions to `.requireLogin` and the embedded checkout button re-presents the login sheet automatically. The user signs in again; the in-flight checkout resumes.
- **SDK Session token failure** → the SDK calls your `sessionExpirationHandler`, re-runs the bootstrap with the fresh token, and retries the in-flight request silently.

### 3. Get Checkout Requirements

`getCheckoutRequirements()` calls the intent endpoint, validates amount limits, determines whether OnramperID login is needed, and returns a self-contained SwiftUI view — a "Buy" button with a Terms-of-Service consent sentence below.

```swift
let result = try await sdk.getCheckoutRequirements(
    .init(
        onramperTransactionData: .init(
            source: "usd",
            destination: "btc",     // required — the asset the user receives
            amount: 100,
            type: .buy,
            country: "us",            // optional — derived from request IP if omitted
            subdivision: "us-ca",     // optional, recommended for US
            paymentMethod: "applepay",
            wallet: .init(network: "bitcoin", address: "bc1q...")
        ),
        onlyOnramps: nil  // optional whitelist
    ),
    prefill: .init(                    // optional — see "Prefilling known user values"
        // email: "ada@example.com",   // only if you're sure — see the caveat there
        firstName: "Ada",
        lastName: "Lovelace",
        phoneNumber: "+3712345678"
    ),
    buttonStyle: .init(backgroundColor: .blue, foregroundColor: .white, borderRadius: 12)
)

// result.button: OnramperCheckoutButton — embed this (Buy + ToS sentence)
// result.quote:  QuoteResponse          — always a successful quote; its fields
//                (quoteId, ramp, rate, payout, paymentMethod, networkFee,
//                transactionFee) are non-optional. A request that can't be
//                priced fails with OnramperError instead.
```

`country` (ISO 3166-1 alpha-2) and `subdivision` (ISO 3166-2, e.g. `"us-ca"`) are both optional. Omit them and the Onramper backend will derive both from the request IP. Pass them only when you already know the user's location (e.g. from your own KYC) — the backend treats integrator-supplied values as authoritative for compliance gating.

#### Request parameters

`onramperTransactionData` (`OnramperTransactionData`):

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | `String` | Yes | Source (fiat) asset ISO code, e.g. `"usd"`. Lowercased by the SDK. |
| `destination` | `String` | Yes | Destination (crypto) asset the user receives, e.g. `"btc"`. Lowercased by the SDK. |
| `amount` | `Double` | Yes | Amount in the `source` currency. |
| `type` | `TransactionType` | Yes | `.buy` or `.sell`. |
| `country` | `String?` | No | ISO 3166-1 alpha-2 (e.g. `"us"`). Derived from the request IP when omitted. |
| `subdivision` | `String?` | No | ISO 3166-2 (e.g. `"us-ca"`). Strongly recommended for US. |
| `paymentMethod` | `String` | Yes | Payment method id, e.g. `"applepay"`. |
| `wallet` | `WalletInfo` | Yes | Destination wallet — see below. |

`WalletInfo`:

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `network` | `String` | Yes | Wallet network, e.g. `"bitcoin"`. |
| `address` | `String` | Yes | Destination wallet address. |
| `memo` | `String?` | No | Destination tag / memo, when the network requires one. |

Top-level call:

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `onlyOnramps` | `[String]?` | No | Allowlist of provider ids to consider. `nil` = all eligible providers. |
| `prefill` | `OnramperUserPrefill?` | No | Values you already know about the user, used to pre-populate the OnramperID screens. Best-effort — see below. |
| `buttonStyle` | `CheckoutButtonStyle?` | No | Button appearance: `backgroundColor` (`Color`, default `.blue`), `foregroundColor` (`Color`, default `.white`), `borderRadius` (`CGFloat`, default `12`). |

#### Prefilling known user values

If your app already knows the user — from your own account system, a previous purchase, or your own KYC — pass those values as `prefill` and the OnramperID screens arrive pre-populated instead of blank.

```swift
let result = try await sdk.getCheckoutRequirements(
    request,
    prefill: OnramperUserPrefill(
        email: "ada@example.com",
        firstName: "Ada",
        lastName: "Lovelace",
        phoneNumber: "+3712345678"   // E.164
    )
)
```

| Field | Format | Notes |
|-------|--------|-------|
| `email` | valid email address | Identifies which account the other values belong to — read the warning below before supplying it. |
| `firstName` | up to 200 characters, no `<` or `>` | Must not be blank. |
| `lastName` | up to 200 characters, no `<` or `>` | Must not be blank. |
| `phoneNumber` | E.164, e.g. `+3712345678` | Always a *candidate*: the user still verifies it, and a number already verified on the account takes precedence. Prefill never skips phone verification. |

Every field is optional — supply only what you know. An `email`-only prefill is valid and pre-populates just the sign-in field.

**Prefill never blocks sign-in.** If it cannot be applied, the login sheet opens normally without it. There is no error to handle and nothing surfaces to your app; set `logLevel: .info` while integrating if you want to see whether it was applied.

> **Supply `email` only when you're confident.** It identifies which account the other values belong to, so it is not just another prefilled value. If it matches the account that signs in, the remaining values may be applied automatically. If it does **not** match, the **whole** prefill is dropped — strictly worse than omitting `email`, where the values are still offered to the user for confirmation. When you aren't sure which address the user will use, leave `email` out.

Whether prefilled values are shown to the user for confirmation or applied without a prompt is configured per integration, as is prefill itself. Talk to your Onramper representative before relying on it — without it enabled, sign-in simply proceeds without prefill.

#### Quote fields

`result.quote` (`QuoteResponse`) is always a **successful** quote — a request that can't be priced fails with `OnramperError` instead, so the core fields are never null.

| Field | Type | Description |
|-------|------|-------------|
| `quoteId` | `String` | Unique id for this quote (echoed back on finalize). |
| `ramp` | `String` | Provider (onramp) id that priced the trade, e.g. `"moonpay"`. |
| `rate` | `Double` | Exchange rate applied to the trade. |
| `payout` | `Double` | Amount of the destination asset the user receives. |
| `paymentMethod` | `String` | Payment method the quote was priced for, e.g. `"applepay"`. |
| `networkFee` | `Double` | Network/processing fee for the trade. |
| `transactionFee` | `Double` | Provider transaction fee for the trade. |
| `recommendations` | `[String]?` | Optional provider recommendation metadata. |
| `providerContext` | `[String: ProviderJSONValue]?` | Provider-specific JSON data. Most integrations can ignore it; use `.stringValue` to read a string entry. For MoonPay it carries the payment disclosures the SDK displays for you. |

Embed the returned view in your UI. When tapped, the button handles everything: OIDC login sheet (if required), finalize call (with the user's ToS-acceptance timestamp captured at tap), and payment webview sheet.

```swift
struct BuyView: View {
    @StateObject var sdk: OnramperClient
    @State private var checkoutButton: OnramperCheckoutButton?

    var body: some View {
        VStack {
            if let checkoutButton {
                checkoutButton
            } else {
                ProgressView()
            }
        }
        .task {
            checkoutButton = try? await sdk.getCheckoutRequirements(request).button
        }
    }
}
```

### 4. Requirements Handling

Requirements are a typed Swift enum (`CheckoutRequirement.tos / .amountLimit / .userInfo / .reverification`) decoded from the Onramper backend's discriminated-union wire format. The SDK consumes them so you don't have to:

| Type | SDK Handling |
|------|--------------|
| `tos` | Renders a markdown consent sentence below Buy: `By clicking "Buy" button above I agree with Coinbase [Terms of Service](url) and [Privacy Policy](url)`. ToS / Privacy / User-Agreement links appear inline; satisfied items are filtered out. Also exposed via `sdk.tosRequirements: [ToSRequirement]?`. |
| `amount_limit` | Validated locally during `getCheckoutRequirements()`. Throws `OnramperError.amountOutOfRange`. |
| `user_info` | SDK transitions to `.requireLogin`. Tapping Buy presents the OIDC login sheet automatically with `required_user_fields` derived from the unsatisfied required entries. Pass `prefill` to `getCheckoutRequirements` to have these fields arrive pre-populated — see [Prefilling known user values](#prefilling-known-user-values). |
| `reverification` (phone) | SDK transitions to `.requireLogin` and presents the OnramperID flow with `phone_reverification=true` — the user re-verifies their **existing** phone number (they can't change it). The backend only emits this when re-verification is actually due, so the SDK acts on its presence without re-checking recency. Email reverification has no client flow yet. |

The agreement timestamp is captured at the moment the user taps Buy and sent in the finalize request as ISO-8601, so the Onramper backend can audit that consent was given alongside the transaction.

### Payment surface

After Buy, the SDK finalizes the checkout and presents the payment surface the provider needs — you don't choose or configure it. For **MoonPay with Apple Pay**, the SDK runs MoonPay's checkout inside the sheet: it handles guest checkout or MoonPay account onboarding when required, any 3-D Secure verification, and shows MoonPay's required payment disclosures next to the Apple Pay button. The disclosures can't be hidden.

The checkout ends in one of three ways:

| Outcome | State | What to do |
|---|---|---|
| Completed | `.completed` | Done. |
| Accepted, settlement pending (MoonPay) | `.paymentPending` | The payment was accepted but the crypto transfer is still underway. The SDK shows "Payment processing" with the transaction id. **Don't treat it as success or failure** — track it with `currentTransactionId` through your own status flow. Dismissing the sheet keeps this outcome. |
| Failed | `.failed(OnramperError)` | The SDK shows the error's `userMessage` and support code with a **Try Again** button, which closes the sheet and starts a fresh checkout. |

### 5. Re-requesting Checkout

Call `getCheckoutRequirements()` from any post-init state to restart the flow (e.g., the user changed amount, payment method, or country). The SDK internally resets checkout state and returns a fresh component.

```swift
checkoutButton = try await sdk.getCheckoutRequirements(updatedRequest).button
```

**Concurrent calls are coalesced.** If a new `getCheckoutRequirements()` call arrives while a previous one is still in flight (e.g., the user rapidly toggles a country picker), the SDK cancels the prior call and starts the new one. The superseded `await` throws `CancellationError`, which you should ignore:

```swift
do {
    let result = try await sdk.getCheckoutRequirements(updatedRequest)
    checkoutButton = result.button
} catch is CancellationError {
    // user changed inputs again before this call finished — ignore
} catch {
    showError(error)
}
```

No need to debounce the picker or check `sdk.state` first.

### 6. Reset

`reset()` is async — call after completion or failure if you want to return the SDK to `.ready`:

```swift
await sdk.reset()
```

`reset()` keeps the user's OnramperID login active so the next checkout skips the login sheet. To clear the stored OIDC tokens (a "Sign out" / "Switch account" affordance, or when your app's own user logs out), call `signOut()`:

```swift
await sdk.signOut()
// Clears the stored OIDC access + refresh tokens and calls reset(). The next
// checkout that requires `user_info` re-presents the OnramperID login sheet.
// The SDK session (DPoP key + partner session) is preserved — no need to
// re-call initialize(...) unless that session itself has expired.
```

## State Machine

The SDK exposes observable state so you can build UI around it:

```
idle → initializing → ready ──→ checkoutPreparing
                       ^               │
                       │               ├→ requireLogin ──→ authenticating ─┐
                       │               │       ^               │           │
                       │               │       └───────────────┘           │
                       │               │   (OIDC sheet dismissed)          │
                       │               │                                   │
                       │               └→ readyToCheckout ←────────────────┘
                       │ (reset)             │
                       │                     v
completed ←── rendering ←── finalizing
    │            │
    v            ├→ paymentPending   (accepted, settlement pending)
  failed ←── (any state)

# Re-request: any post-init state can transition back to checkoutPreparing.
# paymentPending is neither success nor failure; reset() or a re-request leaves it.
# Login cancel: dismissing the OIDC sheet bounces .authenticating back to .requireLogin
# (Buy is tappable again to retry).
```

## Observing State

Three patterns are supported — use whichever fits your architecture:

### SwiftUI (recommended)

```swift
@StateObject var sdk = OnramperClient(configuration: config)

// Automatically re-renders when sdk.state changes
Text("State: \(sdk.state.label)")
```

Published properties: `state`, `lastError`, `tosRequirements`, `currentTransactionId`.

### The transaction id

`currentTransactionId` is Onramper's durable identifier for the transaction. It is populated the moment the checkout is finalized — before the payment surface renders — and stays readable until you start another checkout or call `reset()`.

```swift
sdk.$currentTransactionId
    .compactMap { $0 }
    .sink { transactionId in analytics.log(transactionId) }
```

**This is the id to store, and the one to quote to Onramper support.** It is distinct from the checkout id delivered by `checkoutStarted` / `didStartCheckout` and `completed` / `didCompleteCheckout`, which identifies a single checkout *attempt* — a new one is issued every time the intent is re-created, including each time the user dismisses the payment sheet. One user journey can burn several checkout ids while producing at most one transaction id.

If you consume the event stream, the same value is on the finalize response as `onramperTransactionId`. Read `currentTransactionId` before calling `reset()`, which clears it.

### Delegate (UIKit)

```swift
sdk.delegate = self

func onramperClient(_ client: OnramperClient, didChangeState state: OnramperState) { }
func onramperClient(_ client: OnramperClient, didStartCheckout checkoutId: String) { }
func onramperClient(_ client: OnramperClient, didRequireLogin requirements: [CheckoutRequirement]) { }
func onramperClient(_ client: OnramperClient, didBecomeReadyToCheckout checkoutId: String) { }
func onramperClient(_ client: OnramperClient, didCompleteCheckout checkoutId: String) { }
func onramperClient(_ client: OnramperClient, didFailWithError error: OnramperError) { }
func onramperClient(_ client: OnramperClient, didReceiveProviderEvent event: CheckoutEvent) { }  // provider lifecycle, see below
```

All delegate methods have default no-op implementations — adopt only the ones you need.

### AsyncStream (Swift concurrency)

```swift
for await event in sdk.events {
    switch event {
    case .stateChanged(let state): break
    case .checkoutStarted(let checkoutId): break
    case .loginRequired(let requirements): break
    case .readyToCheckout: break
    case .requirementSatisfied(let type): break
    case .checkoutFinalized(let response): break
    case .renderingStarted(let url, let renderType): break
    case .completed(let checkoutId): break
    case .failed(let error): break
    case .checkoutCancelled: break  // user dismissed the payment webview; SDK re-prepares the intent and returns to .readyToCheckout

    // Provider lifecycle (also delivered via didReceiveProviderEvent) — informational, the SDK drives the flow
    case .providerReady, .paymentAuthorized, .paymentProcessing: break
    case .paymentPending: break     // accepted, settlement pending; no .completed follows
    case .paymentCancelled: break   // cancelled in the provider UI; .checkoutCancelled follows
    case .providerError(let reason): break  // diagnostic code, not user copy; .failed follows
    case .challengeStarted, .challengeCompleted: break  // MoonPay 3-D Secure verification
    case .customerOnboardingRequired: break  // MoonPay guest checkout unavailable; SDK opens MoonPay onboarding
    }
}
```

## Error Handling

All errors are typed via `OnramperError`. The surface is intentionally small and stable — internal recovery signals (token refresh, re-bootstrap, DPoP plumbing) are handled inside the SDK and never surface to integrators.

```swift
do {
    try await sdk.initialize(sessionId: sessionId, sessionToken: sessionToken)
} catch let error as OnramperError {
    switch error {
    // Initialization / lifecycle
    case .notInitialized: break
    case .initializationFailed(let reason): break
    case .attestationFailed(let reason): break
    case .invalidStateTransition(let from, let to): break
    case .invalidState(let expected, let actual): break

    // Onramper backend / checkout surface
    case .invalidRequest(let field, let debugInfo): break         // 4xx validation; `field` names the offending parameter when known
    case .quoteUnavailable(let debugInfo): break                  // no provider returned a usable quote
    case .checkoutForbidden(let debugInfo): break                 // region / KYC tier / partner policy block
    case .temporaryFailure(let retryAfter, let debugInfo): break  // 5xx; `retryAfter` populated when `Retry-After` header present
    case .unrecoverable(let debugInfo): break                     // catch-all; re-initialize and try again
    case .configurationError(let reason): break                   // partner-side setup error (bad api key, insufficient scope, etc.)

    // Local validation
    case .amountOutOfRange(let min, let max): break
    case .requirementNotSatisfied(let type): break

    // Security
    case .deviceBlocked: break                                    // server rejected the device — terminal
    case .securityStorageFailed(let osStatus): break
    case .securityTrustFailed(let host): break                    // TLS certificate pinning failed — terminal, don't retry

    // OnramperID
    case .oidcFlowCancelled: break
    case .oidcFlowFailed(let reason): break
    case .oidcTokenExchangeFailed(let reason): break
    case .userTokenInvalid: break                                 // surfaced only if SDK reactive retry also fails
    case .userTokenRefreshFailed(let reason): break               // OIDC refresh terminally rejected; SDK has already transitioned to .requireLogin

    // Rendering / payment
    case .webviewLoadFailed(let reason): break
    case .deepLinkFailed(let reason): break
    case .paymentFailed(let message): break                       // provider confirmed the payment failed (e.g. card declined)
    case .providerFailed(let message): break                      // payment surface failed; payment outcome NOT confirmed
    case .applePayNotConfigured: break                            // no Apple Pay card in Wallet on this device

    // Networking
    case .networkError(let code, let message): break
    case .decodingError(let detail): break
    case .timeout: break
    }
}
```

For UI, use `userMessage` — plain, non-technical copy that is safe to show end users (never a URL, token or error domain; English only) — and `supportCode`, a short stable code that is safe to show next to it and matches what the SDK logs. `errorDescription` and `debugInfo` are diagnostic text for logs, not for end users:

```swift
} catch let error as OnramperError {
    showAlert(message: error.userMessage, footnote: "Error code: \(error.supportCode)")
}
```

> `debugInfo` is opaque and intended for support tickets / crash reports — log it but don't switch on its contents.

> **`.providerFailed` after a status error:** the payment may already have gone through. Its `userMessage` tells the user to check their transaction before trying again — keep that guidance visible if you show your own error UI.

## Security Model

The SDK ships with a full DPoP / App Attest implementation. You don't need to wire any of it — it's automatic — but here's some insights on happening under the hood:

| Step | Action |
|---|---|
| Once per install | Generate an EC P-256 key in the Secure Enclave (`com.onramper.sdk.dpop-key`). Generate an App Attest key when supported. |
| `initialize(sessionId:sessionToken:)` | Fetch attestation challenge, run App Attest (or mark Tier 2 if unsupported), build a DPoP proof, exchange the session token for an access/refresh pair. |

`PrivacyInfo.xcprivacy` ships inside the framework declaring `NSPrivacyCollectedDataTypeDeviceID` (the SHA-256 device fingerprint that the Onramper backend uses for fraud detection and session binding).

## Logging

The SDK is silent by default (`logLevel: .off`). Set `logLevel` on `OnramperConfiguration` to receive structured, sanitized `OnramperLogRecord`s. By default they go to `os.Logger` under the subsystem `com.onramper.sdk` (view in Console.app or `log stream`).

| Level | Emits |
|---|---|
| `.off` *(default)* | Nothing. Use in production. |
| `.error` | Failures — non-2xx responses, decoded error codes, terminal checkout failures. |
| `.info` | Adds one record per milestone: security bootstrap, requests (method, route template, status, duration), state changes, provider frames. |
| `.debug` | Adds request starts and low-level detail, including payment-page JavaScript errors. |

Supply `logHandler` to send records to your own sink — for example a file you let testers export. A custom handler **replaces** the `os.Logger` output; compose it with `OnramperLog.systemHandler` to keep both:

```swift
OnramperConfiguration(
    apiKey: "pk_live_...",
    clientId: "YOUR_ONRAMPER_ID_CLIENT_ID",
    logLevel: .debug,
    logHandler: { record in
        OnramperLog.systemHandler(record)   // keep Xcode / Console output
        myLogStore.append(record)           // your sink
    },
    sessionExpirationHandler: { /* … */ }
)
```

Each record has `timestamp`, `level`, `category` (e.g. `HTTP`, `Checkout`, `OIDC`), `event` (a stable name such as `request.finished`), `context` (`[String: String]`, already sanitized) and `message` — a single line like `request.finished durationMs=184 method=POST route=v1/checkout/intent status=200`. Categories, event names and context keys are stable.

The handler is called synchronously on whichever thread emits the record (main thread, SDK actors, background queues): keep it fast and thread-safe, don't call back into the SDK, and hop to the main thread yourself if your sink needs it.

**Privacy.** The SDK never logs tokens, credentials, DPoP proofs, attestation objects, request or response bodies, card data or prefill values. URLs are reduced to their host, HTTP paths to route templates, wallet addresses are masked, and errors are summarized. A final sanitizer also redacts anything that looks like a URL, email, phone number, card number or token. Provider error messages and (at `.debug`) payment-page JavaScript errors are kept for diagnosis after this best-effort redaction, so **treat exported logs as potentially containing personal data**. Your app owns their storage, retention and export.

## Distribution

Distributed as a precompiled `.xcframework` (iOS device + simulator slices) attached to each GitHub Release. The `Package.swift` in this repo points at the matching tag's asset and is regenerated automatically per release.

Source is not part of this repository.

## Support

Contact your Onramper integration representative.

## License

OnramperSDK is released under the Apache License 2.0. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).

Copyright © 2026 Onramper Technologies B.V.
