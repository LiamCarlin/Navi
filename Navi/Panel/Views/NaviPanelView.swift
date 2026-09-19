import SwiftUI

/// PLACEHOLDER — replaced by the Panel UI workstream with the Liquid Glass design.
/// Contract: renders `PanelViewModel` state; must keep the same type name.
struct NaviPanelView: View {
    @EnvironmentObject var vm: PanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkle")
                TextField("Ask Navi or type an app name…", text: $vm.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .light))
            }
            .padding(16)
            if !vm.results.isEmpty {
                ForEach(Array(vm.results.enumerated()), id: \.element.id) { i, r in
                    HStack {
                        Text(r.title)
                        Spacer()
                        if let s = r.subtitle { Text(s).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(i == vm.selectedIndex ? Color.accentColor.opacity(0.25) : .clear)
                }
            }
            if vm.mode == .answer {
                ScrollView { Text(vm.answerText).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 320).padding(16)
            }
            if !vm.statusLine.isEmpty { Text(vm.statusLine).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8) }
        }
        .frame(width: PanelController.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
