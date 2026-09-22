import SwiftUI
import AppKit

/// The ranked result rows under the search bar. Up to eight rows are visible;
/// longer lists scroll. Hover selects, click performs, the selection highlight
/// glides between rows.
struct ResultsListView: View {
    @EnvironmentObject private var vm: PanelViewModel
    @Namespace private var selectionNS
    /// Last pointer location that drove a hover-selection. Rows shifting under
    /// a resting pointer (e.g. after ↓ scrolls the list) must not steal the
    /// keyboard selection, so hover only selects when the pointer really moved.
    @State private var lastHoverPoint: CGPoint = .zero

    private var listHeight: CGFloat {
        let rows = min(vm.results.count, PanelStyle.maxVisibleRows)
        return CGFloat(rows) * PanelStyle.rowHeight + 2 * PanelStyle.listPad
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 1) {
                    ForEach(Array(vm.results.enumerated()), id: \.element.id) { i, r in
                        ResultRow(result: r, isSelected: i == vm.selectedIndex, namespace: selectionNS)
                            .id(r.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                vm.selectedIndex = i
                                vm.perform(r)
                            }
                            .onContinuousHover(coordinateSpace: .global) { phase in
                                guard case .active(let p) = phase else { return }
                                if abs(p.x - lastHoverPoint.x) > 1.5 || abs(p.y - lastHoverPoint.y) > 1.5 {
                                    lastHoverPoint = p
                                    if vm.selectedIndex != i { vm.selectedIndex = i }
                                }
                            }
                            .transition(.identity)
                    }
                }
                .padding(.horizontal, PanelStyle.listPad)
                .padding(.vertical, PanelStyle.listPad)
            }
            .scrollIndicators(.never)
            .frame(height: listHeight)
            .onChange(of: vm.selectedIndex) { _, idx in
                if let id = vm.results[safe: idx]?.id { proxy.scrollTo(id, anchor: nil) }
            }
        }
        .animation(PanelStyle.quickSpring, value: vm.selectedIndex)
    }
}

// MARK: - Row

struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 12) {
            ResultIconView(icon: result.icon, kind: result.kind)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let s = result.subtitle, !s.isEmpty {
                    Text(s)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: PanelStyle.rowHeight)
        .background {
            if isSelected {
                PanelStyle.rowShape
                    .fill(PanelStyle.selectionFill)
                    .overlay(PanelStyle.rowShape.strokeBorder(Color.primary.opacity(0.06)))
                    .matchedGeometryEffect(id: "selection", in: namespace)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isSelected, let hint = result.shortcutHint, !hint.isEmpty {
            ShortcutHint(text: hint)
                .transition(.opacity)
        } else {
            Text(PanelStyle.label(for: result.kind))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

/// "⏎ Open" rendered as key cap + verb.
struct ShortcutHint: View {
    let text: String
    var body: some View {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        HStack(spacing: 5) {
            if let k = parts.first { KeyCap(text: k) }
            if parts.count > 1 {
                Text(parts[1]).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}

/// Quiet row shown when a query has no matches yet.
struct AskNaviHintRow: View {
    let query: String
    var body: some View {
        HStack(spacing: 12) {
            ResultIconView(icon: .system("sparkle"), kind: .answer)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ask Navi")
                    .font(.system(size: 15, weight: .medium))
                Text("Answer “\(query)”")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            ShortcutHint(text: "⏎ Ask")
        }
        .padding(.horizontal, 12)
        .frame(height: PanelStyle.rowHeight)
        .background(PanelStyle.rowShape.fill(PanelStyle.selectionFill))
        .padding(PanelStyle.listPad)
    }
}

// MARK: - Icons

/// Renders a `ResultIcon`: SF Symbol in a tinted square, app/file icon, or bitmap.
struct ResultIconView: View {
    let icon: ResultIcon
    let kind: ResultKind

    var body: some View {
        switch icon {
        case .system(let name):
            let tint = PanelStyle.tint(for: kind)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .overlay {
                    Image(systemName: name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolRenderingMode(.hierarchical)
                }
                .shadow(color: tint.opacity(0.25), radius: 3, y: 1)
        case .appBundle(let path), .file(let path):
            Image(nsImage: AppIconCache.shared.icon(forPath: path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        case .image(let img):
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

/// Small LRU-ish cache of `NSWorkspace` icons keyed by path. Rows re-render on
/// every keystroke, so icon lookups must not hit the workspace each time.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private let limit = 256

    func icon(forPath path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 32, height: 32)
        cache[path] = img
        order.append(path)
        if order.count > limit, let oldest = order.first {
            order.removeFirst()
            cache[oldest] = nil
        }
        return img
    }
}
