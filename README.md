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
    .package(url: "https://github.com/onramper/onramper-ios.git", from: "1.0.0")
]
```

…and add `OnramperSDK` to the relevant target's dependencies:

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "OnramperSDK", package: "onramper-ios"),
])
```

Or in Xcode: **File → Add Package Dependencies** and enter the repository URL.

> **Private-access note.** While this repo is private, SwiftPM needs an authenticated path to download the xcframework release asset. Add your GitHub account in **Xcode → Settings → Accounts** (with a PAT that has `repo` scope), or drop a `~/.netrc` entry for `api.github.com` and `github.com`. CLI/CI builds need the netrc; Xcode picks it up from the account list.

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
let checkoutButton = try await sdk.getCheckoutRequirements(
    .init(
        onramperTransactionData: .init(
            onramp: "moonpay",
            source: "USD",
            destination: "BTC",
            amount: 100,
            type: .buy,
            country: "US",
            paymentMethod: "applepay",
            wallet: .init(network: "bitcoin", address: "bc1q...")
        ),
        onlyOnramps: nil  // optional whitelist
    ),
    buttonStyle: .init(backgroundColor: .blue, foregroundColor: .white, borderRadius: 12)
)
```

`country` (ISO 3166-1 alpha-2) and `subdivision` (ISO 3166-2, e.g. `"us-ca"`) are both optional. Omit them and the Onramper backend will derive both from the request IP. Pass them only when you already know the user's location (e.g. from your own KYC) — the backend treats integrator-supplied values as authoritative for compliance gating.

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
            checkoutButton = try? await sdk.getCheckoutRequirements(request)
        }
    }
}
```

### 4. Requirements Handling

Requirements are a typed Swift enum (`CheckoutRequirement.tos / .amountLimit / .userInfo`) decoded from the Onramper backend's discriminated-union wire format. The SDK consumes them so you don't have to:

| Type | SDK Handling |
|------|--------------|
| `tos` | Renders a markdown consent sentence below Buy: `By clicking "Buy" button above I agree with Coinbase [Terms of Service](url) and [Privacy Policy](url)`. ToS / Privacy / User-Agreement links appear inline; satisfied items are filtered out. Also exposed via `sdk.tosRequirements: [ToSRequirement]?`. |
| `amount_limit` | Validated locally during `getCheckoutRequirements()`. Throws `OnramperError.amountOutOfRange`. |
| `user_info` | SDK transitions to `.requireLogin`. Tapping Buy presents the OIDC login sheet automatically with `required_user_fields` derived from the unsatisfied required entries. |

The agreement timestamp is captured at the moment the user taps Buy and sent in the finalize request as ISO-8601, so the Onramper backend can audit that consent was given alongside the transaction.

### 5. Re-requesting Checkout

Call `getCheckoutRequirements()` from any post-init state to restart the flow (e.g., the user changed amount, payment method, or country). The SDK internally resets checkout state and returns a fresh component.

```swift
checkoutButton = try await sdk.getCheckoutRequirements(updatedRequest)
```

**Concurrent calls are coalesced.** If a new `getCheckoutRequirements()` call arrives while a previous one is still in flight (e.g., the user rapidly toggles a country picker), the SDK cancels the prior call and starts the new one. The superseded `await` throws `CancellationError`, which you should ignore:

```swift
do {
    checkoutButton = try await sdk.getCheckoutRequirements(updatedRequest)
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
    v            v
  failed ←── (any state)

# Re-request: any post-init state can transition back to checkoutPreparing.
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

### Delegate (UIKit)

```swift
sdk.delegate = self

func onramperClient(_ client: OnramperClient, didChangeState state: OnramperState) { }
func onramperClient(_ client: OnramperClient, didStartCheckout checkoutId: String) { }
func onramperClient(_ client: OnramperClient, didRequireLogin requirements: [CheckoutRequirement]) { }
func onramperClient(_ client: OnramperClient, didBecomeReadyToCheckout checkoutId: String) { }
func onramperClient(_ client: OnramperClient, didCompleteCheckout checkoutId: String) { }
func onramperClient(_ client: OnramperClient, didFailWithError error: OnramperError) { }
```

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

    // OnramperID
    case .oidcFlowCancelled: break
    case .oidcFlowFailed(let reason): break
    case .oidcTokenExchangeFailed(let reason): break
    case .userTokenInvalid: break                                 // surfaced only if SDK reactive retry also fails
    case .userTokenRefreshFailed(let reason): break               // OIDC refresh terminally rejected; SDK has already transitioned to .requireLogin

    // Rendering
    case .webviewLoadFailed(let reason): break
    case .deepLinkFailed(let reason): break

    // Networking
    case .networkError(let code, let message): break
    case .decodingError(let detail): break
    case .timeout: break
    }
}
```

> `debugInfo` is opaque and intended for support tickets / crash reports — log it but don't switch on its contents.

## Security Model

The SDK ships with a full DPoP / App Attest implementation. You don't need to wire any of it — it's automatic — but here's what's happening under the hood:

| Step | Action |
|---|---|
| Once per install | Generate an EC P-256 key in the Secure Enclave (`com.onramper.sdk.dpop-key`). Generate an App Attest key when supported. |
| `initialize(sessionId:sessionToken:)` | Fetch attestation challenge, run App Attest (or mark Tier 2 if unsupported), build a DPoP proof, exchange the session token for an access/refresh pair. |
| Every backend call | Fresh DPoP proof per request (`htu`/`htm`/`iat`/`jti`/`ath`) + per-request `X-Onramper-*` security headers. |
| Proactive refresh | Within 60s of expiry, the SDK refreshes the relevant token (Session or OIDC) before sending the next request. Single-flight: concurrent calls coalesce onto one refresh. |
| 401 SDK session | Refresh once; on terminal failure call `sessionExpirationHandler`, re-run bootstrap, retry the original request — silent. |
| 401 OIDC user | Refresh once; on terminal failure transition to `.requireLogin` and re-present the login sheet — silent. |

Tier 2 (no App Attest) is sent as `attestation: { type: "none" }` during exchange — useful for simulators and devices without App Attest support; the server decides what that token can do.

`PrivacyInfo.xcprivacy` ships inside the framework declaring `NSPrivacyCollectedDataTypeDeviceID` (the SHA-256 device fingerprint that the Onramper backend uses for fraud detection and session binding).

## Logging

Set `logLevel` on `OnramperConfiguration` to control the SDK's diagnostic output. Routed through `os.Logger` under the subsystem `com.onramper.sdk`; view in Console.app or `log stream`.

| Level | Emits |
|---|---|
| `.off` *(default)* | Nothing. Use in production. |
| `.error` | Failed requests only — non-2xx status + decoded error code. |
| `.info` | Adds method + URL path + status for every request. |
| `.debug` | Adds low-level detail. |

The SDK never logs session tokens, attestation objects, refresh tokens, or response bodies in a release build. Verbatim header/body dumps are stripped at compile time from release artifacts.

## Versioning

Semantic versioning per [SemVer 2.0.0](https://semver.org). The xcframework is built with Library Evolution enabled, so consumers are not pinned to the exact Swift compiler version it was built with.

See [CHANGELOG.md](./CHANGELOG.md) for release history.

## Distribution

Distributed as a precompiled `.xcframework` (iOS device + simulator slices) attached to each GitHub Release. The `Package.swift` in this repo points at the matching tag's asset and is regenerated automatically per release.

Source is not part of this repository.

## Support

Contact your Onramper integration representative.

## License

Copyright © 2026 Onramper. All rights reserved.
