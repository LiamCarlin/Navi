import SwiftUI

/// PLACEHOLDER — replaced by the Settings workstream.
/// Contract: the main "Navi" app window; must keep the same type name.
struct SettingsRootView: View {
    @EnvironmentObject var settings: NaviSettings
    var body: some View {
        VStack(spacing: 12) {
            Text("Navi").font(.largeTitle)
            Text("Settings placeholder").foregroundStyle(.secondary)
            Toggle("Screen Memory", isOn: $settings.memoryCaptureEnabled)
        }
        .padding(40)
    }
}
