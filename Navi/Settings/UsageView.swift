import SwiftUI

/// Local, rough cost tracking. Token counts come from provider responses;
/// prices are list prices per million tokens (Sept 2026).
enum Pricing {
    struct Rate { let input: Double; let output: Double }   // $ per MTok

    static func claude(_ model: String) -> Rate {
        if model.contains("opus") { return Rate(input: 5, output: 25) }
        if model.contains("sonnet") { return Rate(input: 2, output: 10) }
        return Rate(input: 1, output: 5)                     // haiku 4.5
    }
    static let jevInputPerMTok = 0.042
    /// Typical Navi Jev request (structured state + a few questions).
    static let jevTokensPerCall = 1_200.0
}

struct UsageView: View {
    @EnvironmentObject private var settings: NaviSettings
    @State private var confirmReset = false

    private var rate: Pricing.Rate { Pricing.claude(settings.answerModel) }
    private var claudeCost: Double {
        Double(settings.usageClaudeInputTokens) / 1e6 * rate.input + Double(settings.usageClaudeOutputTokens) / 1e6 * rate.output
    }
    private var jevCost: Double {
        Double(settings.usageJevCalls) * Pricing.jevTokensPerCall / 1e6 * Pricing.jevInputPerMTok
    }

    var body: some View {
        FormPage(title: "Usage", subtitle: "Counted on this Mac since the last reset. Dollar figures are estimates from list prices.") {
            Section {
                HStack(spacing: 12) {
                    tile("Jev calls", Fmt.tokens(settings.usageJevCalls), Fmt.usd(jevCost), "bolt.fill")
                    tile("Claude in", Fmt.tokens(settings.usageClaudeInputTokens), Fmt.usd(Double(settings.usageClaudeInputTokens) / 1e6 * rate.input), "arrow.down.circle")
                    tile("Claude out", Fmt.tokens(settings.usageClaudeOutputTokens), Fmt.usd(Double(settings.usageClaudeOutputTokens) / 1e6 * rate.output), "arrow.up.circle")
                    tile("Digested frames", Fmt.tokens(settings.usageDigestFrames), "", "photo.stack")
                }
                .padding(.vertical, 4)
                LabeledContent("Estimated total") {
                    Text(Fmt.usd(claudeCost + jevCost)).font(.title3.weight(.semibold)).monospacedDigit()
                }
            }

            Section("Prices used") {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
                    GridRow {
                        Text("Model").font(.caption).foregroundStyle(.secondary)
                        Text("Input / MTok").font(.caption).foregroundStyle(.secondary)
                        Text("Output / MTok").font(.caption).foregroundStyle(.secondary)
                    }
                    priceRow("Jev (jev-latest)", "$0.042", "free")
                    priceRow("claude-opus-5", "$5", "$25", highlight: settings.answerModel.contains("opus"))
                    priceRow("claude-sonnet-5", "$2", "$10", highlight: settings.answerModel.contains("sonnet"))
                    priceRow("claude-haiku-4-5", "$1", "$5", highlight: settings.answerModel.contains("haiku"))
                }
                Text("Claude tokens are pooled across models; the estimate applies your Answers model's rate (\(settings.answerModel)). Jev cost assumes ~\(Int(Pricing.jevTokensPerCall)) input tokens per call.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Reset counters", role: .destructive) { confirmReset = true }
                    Spacer()
                }
                .confirmationDialog("Reset all usage counters?", isPresented: $confirmReset) {
                    Button("Reset", role: .destructive) {
                        settings.usageJevCalls = 0
                        settings.usageClaudeInputTokens = 0
                        settings.usageClaudeOutputTokens = 0
                        settings.usageDigestFrames = 0
                    }
                }
            }
        }
    }

    private func tile(_ label: String, _ value: String, _ cost: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(cost.isEmpty ? " " : "≈ \(cost)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func priceRow(_ m: String, _ i: String, _ o: String, highlight: Bool = false) -> some View {
        GridRow {
            Text(m).fontWeight(highlight ? .semibold : .regular)
            Text(i).monospacedDigit()
            Text(o).monospacedDigit()
        }
        .font(.callout)
    }
}
