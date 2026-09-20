import SwiftUI

/// Shared geometry, colours and motion for the Liquid Glass panel.
enum PanelStyle {
    // Geometry (matches Spotlight: 680 pt wide, 64 pt bar).
    static let width: CGFloat = 680   // keep in sync with PanelController.width
    static let cornerRadius: CGFloat = 28
    static let barHeight: CGFloat = 64
    static let rowHeight: CGFloat = 52
    static let rowCornerRadius: CGFloat = 14
    static let maxVisibleRows = 8
    static let hPad: CGFloat = 20          // inset of bar / footer content
    static let listPad: CGFloat = 10       // inset of the results list rows
    static let footerHeight: CGFloat = 32
    /// Transparent margin around the card where its drop shadow is drawn.
    static let shadowInsets = EdgeInsets(top: 24, leading: 44, bottom: 60, trailing: 44)

    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    static var rowShape: RoundedRectangle { RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous) }

    // Motion
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.84)
    /// Card height changes: fast and critically damped. Any overshoot on a
    /// height change reads as the bottom edge bouncing, so no bounce here.
    static let resize = Animation.spring(duration: 0.26, bounce: 0)
    static let quickSpring = Animation.spring(response: 0.22, dampingFraction: 0.9)
    static let pillSpring = Animation.spring(response: 0.38, dampingFraction: 0.68)

    // Colour
    static let accentColors: [Color] = [.indigo, .purple, .pink, .orange]
    static var accentGradient: LinearGradient {
        LinearGradient(colors: accentColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var hairline: Color { Color.primary.opacity(0.08) }
    static var selectionFill: Color { Color.primary.opacity(0.075) }

    /// Tallest the scrolling regions (answer, agent timeline) may grow: the
    /// whole panel stays under ~60 % of the screen.
    @MainActor static var maxScrollHeight: CGFloat {
        let screenH = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        return max(180, screenH * 0.6 - barHeight - footerHeight - 40)
    }

    static func tint(for kind: ResultKind) -> Color {
        switch kind {
        case .app: return .blue
        case .file: return .teal
        case .url: return .cyan
        case .webSearch: return .mint
        case .calculation: return .orange
        case .answer: return .purple
        case .task: return .pink
        case .memory: return .indigo
        case .systemCommand: return .gray
        case .settings: return .gray
        case .suggestion: return .secondary
        }
    }

    static func label(for kind: ResultKind) -> String {
        switch kind {
        case .app: return "Application"
        case .file: return "File"
        case .url: return "Website"
        case .webSearch: return "Web"
        case .calculation: return "Calculator"
        case .answer: return "Ask Navi"
        case .task: return "Agent"
        case .memory: return "Memory"
        case .systemCommand: return "System"
        case .settings: return "Settings"
        case .suggestion: return "Suggestion"
        }
    }
}

/// A tiny key-cap glyph like "⌘⏎" used in footers and hints.
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: 17)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// "⌘⏎  ask" — a key cap followed by a muted verb.
struct KeyHint: View {
    let keys: String
    var label: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            KeyCap(text: keys)
            if let label {
                Text(label).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// 1 px separator line used between the bar, content and footer.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(PanelStyle.hairline).frame(height: 1)
    }
}

extension Collection {
    subscript(safe i: Index) -> Element? { indices.contains(i) ? self[i] : nil }
}
