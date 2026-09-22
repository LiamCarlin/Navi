import SwiftUI

/// The upsell card: one title, one paragraph, one prominent action. Used by
/// Settings → Memory ("Unlock Recall") and the Account page.
struct UpgradeCard: View {
    var symbol: String = "sparkles"
    var title: String
    var message: String
    var priceLine: String? = nil
    var primaryTitle: String
    var primary: () -> Void
    var secondaryTitle: String? = nil
    var secondary: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(action: primary) {
                        Text(primaryTitle).padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.regular)
                    if let secondaryTitle, let secondary {
                        Button(secondaryTitle, action: secondary).buttonStyle(.bordered)
                    }
                    if let priceLine {
                        Text(priceLine).font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.14), Color.accentColor.opacity(0.03)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

extension UpgradeCard {
    /// The Recall upsell, wired to checkout (or sign-in when there is no account yet).
    @MainActor static func recall(account: NaviAccount) -> UpgradeCard {
        if account.isSignedIn {
            return UpgradeCard(symbol: "clock.arrow.circlepath",
                               title: "Unlock Recall",
                               message: "Navi remembers your screen — snapshots, on-device text, a private journal you can ask: “what was I doing yesterday?” Nothing leaves this Mac except short digests.",
                               priceLine: account.tier == .free ? "Pro + Recall · $30/mo" : "$10/mo more",
                               primaryTitle: account.tier == .free ? "Get Pro + Recall" : "Add Recall · $10/mo more",
                               primary: { account.openCheckout(plan: .proRecall, interval: .month) },
                               secondaryTitle: "Yearly · $288",
                               secondary: { account.openCheckout(plan: .proRecall, interval: .year) })
        }
        return UpgradeCard(symbol: "clock.arrow.circlepath",
                           title: "Unlock Recall",
                           message: "Navi remembers your screen so you can ask what you were doing yesterday. Sign in to add Recall to your plan.",
                           primaryTitle: "Sign in to Navi",
                           primary: { account.signIn() })
    }
}
