import SwiftUI

/// The former "AI Providers" page. API keys are a development concern — a
/// user never brings their own — so this now renders the hidden Developer
/// section. `SettingsRootView` (account workstream) keeps instantiating this
/// type for `SettingsSection.providers`; the key rows, connection tests,
/// model pickers and everything else live in `DeveloperView.swift`.
struct ProvidersView: View {
    var body: some View {
        DeveloperView()
    }
}
