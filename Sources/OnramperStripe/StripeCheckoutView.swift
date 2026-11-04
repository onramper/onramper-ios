#if canImport(UIKit)
import SwiftUI
import PassKit
@_spi(OnramperNative) import OnramperSDK

/// The Stripe payment step, shown inside the SDK's normal checkout sheet
/// (`OnramperCheckoutView`) where a provider webview would be, after the
/// normal Buy, terms, OnramperID login and finalize.
///
/// It only renders `StripeCheckoutModel`; it does not own it. The SDK owns
/// the session, so polling carries on after this view is replaced by the
/// SDK's pending screen, and closing the sheet cancels the session through
/// the SDK's normal dismissal path rather than through view teardown.
struct StripeCheckoutView: View {
    @ObservedObject var model: StripeCheckoutModel
    @State private var presenter: UIViewController?

    var body: some View {
        Group {
            if model.phase == .applePay {
                applePayOnly
            } else {
                // Normally hidden (the SDK keeps the sheet off screen until the
                // outcome). Seen only if the sheet was already revealed for the
                // Apple Pay button fallback: progress, without repeating the quote.
                VStack(spacing: 12) {
                    sandboxLabel
                    content
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Apple Pay and Link present from a controller inside this sheet,
        // never through a global key window that may belong to another scene.
        // The model keeps it too (weakly) for a returning Link user's sign-in
        // before Apple Pay, which starts there once Stripe is ready.
        .background(PresenterReader {
            presenter = $0
            model.presenterReady($0)
            model.autoCollectApplePayIfPending(from: $0)
        })
        // Stripe usually becomes ready after the sheet appeared, so try again
        // when the Apple Pay step starts (also after the sign-in before it).
        .onChange(of: model.phase) { _ in
            if let presenter { model.autoCollectApplePayIfPending(from: presenter) }
        }
        // A swipe mid-step (Link, KYC, payment) would cancel it half way; the
        // sheet's close button stays available for a deliberate cancel.
        .interactiveDismissDisabled(model.busy)
        // Except once the payment call was made: closing then would leave the
        // user without the outcome of a payment that may have been charged.
        .preference(key: NativeCheckoutCloseDisabledKey.self, value: model.paymentInFlight)
    }

    /// The Apple Pay step on its own, like MoonPay's: the quote was already
    /// approved with Buy and Apple Pay's sheet shows the total, so the compact
    /// checkout sheet holds only a heading and Apple's button. Its height
    /// sizes the sheet (`ProviderPaymentHeightKey`).
    private var applePayOnly: some View {
        VStack(alignment: .leading, spacing: 20) {
            sandboxLabel
            VStack(alignment: .leading, spacing: 6) {
                Text("Pay with Apple Pay")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Payment processed by Stripe")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            // Normally never seen: the session opens Apple Pay itself and keeps
            // this sheet hidden. The button is the fallback when Apple Pay did
            // not appear, and stays for a retry after a cancelled tap.
            if let presenter, !model.busy {
                NativeApplePayButton { model.collectApplePay(from: presenter) }
                    .frame(height: 50)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 50)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { content in
                Color.clear.preference(key: ProviderPaymentHeightKey.self, value: content.size.height)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var sandboxLabel: some View {
        if model.isSandbox {
            Label("Stripe sandbox", systemImage: "testtube.2")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .applePay:
            // Shown by `applePayOnly` instead (see `body`).
            EmptyView()
        case .loading, .working, .finished:
            ProgressView(model.message).frame(maxWidth: .infinity)
        }
    }
}

private struct NativeApplePayButton: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let action: () -> Void
    func makeUIView(context: Context) -> PKPaymentButton {
        let button = PKPaymentButton(paymentButtonType: .buy, paymentButtonStyle: colorScheme == .dark ? .white : .black)
        button.cornerRadius = 12
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
    func updateUIView(_ uiView: PKPaymentButton, context: Context) { }
}

/// Captures a controller inside the checkout sheet to present Apple Pay and
/// Link from.
private struct PresenterReader: UIViewControllerRepresentable {
    let onReady: (UIViewController) -> Void
    func makeUIViewController(context: Context) -> ReaderController {
        let controller = ReaderController()
        controller.onReady = onReady
        return controller
    }
    func updateUIViewController(_ uiViewController: ReaderController, context: Context) { }
    final class ReaderController: UIViewController {
        var onReady: ((UIViewController) -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onReady?(parent ?? self)
        }
    }
}
#endif
