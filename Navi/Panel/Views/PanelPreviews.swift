import SwiftUI

#if DEBUG
/// Wraps the panel in a desktop-like backdrop so the glass has something to sample.
private struct PreviewBackdrop<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.20, blue: 0.45),
                                    Color(red: 0.55, green: 0.25, blue: 0.55),
                                    Color(red: 0.95, green: 0.55, blue: 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.25)).frame(width: 420).blur(radius: 60).offset(x: -180, y: -120)
            Circle().fill(.yellow.opacity(0.25)).frame(width: 360).blur(radius: 70).offset(x: 220, y: 160)
            content.padding(40)
        }
        .frame(width: 780)
        .environmentObject(NaviSettings.shared)
    }
}

private func jev(_ intent: Intent, _ p: Double, ms: Int = 140, risky: Bool = false) -> RouteDecision {
    RouteDecision(intent: intent, confidence: p, probabilities: [intent: p], isRisky: risky,
                  needsClarification: false, latencyMs: ms, source: .jev)
}

private var previewScreenshot: NSImage {
    let img = NSImage(size: NSSize(width: 640, height: 400))
    img.lockFocus()
    NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.98, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 640, height: 400).fill()
    NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
    NSRect(x: 0, y: 360, width: 640, height: 40).fill()
    NSColor.systemBlue.withAlphaComponent(0.6).setFill()
    NSRect(x: 40, y: 200, width: 300, height: 30).fill()
    NSColor(calibratedWhite: 0.7, alpha: 1).setFill()
    for i in 0..<5 { NSRect(x: 40, y: 60 + i * 26, width: 400 - i * 40, height: 10).fill() }
    img.unlockFocus()
    return img
}

#Preview("Idle bar") {
    PreviewBackdrop {
        NaviPanelView().environmentObject(PanelViewModel.preview())
    }
}

#Preview("Results · Jev decided") {
    PreviewBackdrop {
        NaviPanelView().environmentObject(
            PanelViewModel.preview(query: "maps",
                                   results: PanelViewModel.sampleResults,
                                   decision: jev(.openApp, 0.92),
                                   selectedIndex: 0))
    }
}

#Preview("Results · routing (local)") {
    PreviewBackdrop {
        NaviPanelView().environmentObject(
            PanelViewModel.preview(query: "12% of 340",
                                   results: Array(PanelViewModel.sampleResults[2...3]),
                                   decision: .heuristic(.calculate, confidence: 0.6),
                                   isRouting: true))
    }
}

#Preview("No matches → Ask Navi") {
    PreviewBackdrop {
        NaviPanelView().environmentObject(
            PanelViewModel.preview(query: "why is the sky blue", results: [],
                                   decision: jev(.askQuestion, 0.88, ms: 210)))
    }
}

#Preview("Answer · streaming") {
    PreviewBackdrop {
        NaviPanelView().environmentObject(
            PanelViewModel.preview(query: "explain dns",
                                   decision: jev(.askQuestion, 0.96, ms: 180),
                                   mode: .answer,
                                   answer: PanelViewModel.sampleAnswer,
                                   isAnswering: true))
    }
}

#Preview("Answer · done + toast") {
    PreviewBackdrop {
        NaviPanelView().environmentObject(
            PanelViewModel.preview(query: "explain dns",
                                   decision: jev(.askQuestion, 0.96, ms: 180),
                                   mode: .answer,
                                   answer: PanelViewModel.sampleAnswer,
                                   toast: "Copied"))
    }
}

#Preview("Agent · running") {
    PreviewBackdrop {
        NaviPanelView().environmentObject(
            PanelViewModel.preview(query: "open chrome, search for jev and click the first result",
                                   decision: jev(.computerTask, 0.91, ms: 160),
                                   mode: .agent,
                                   agentTask: "Open Chrome, search for Jev and click the first result",
                                   agentEvents: [
                                    .planned("Open Chrome, focus the address bar, search “jev typesafe”, click the first organic result."),
                                    .step(index: 1, description: "Opening Google Chrome"),
                                    .status("Chrome is frontmost"),
                                    .step(index: 2, description: "Typing “jev typesafe” into the omnibox"),
                                    .step(index: 3, description: "Reading results, looking for the first organic link"),
                                   ],
                                   agentScreenshot: previewScreenshot))
    }
}

#Preview("Agent · approval") {
    PreviewBackdrop {
        NaviPanelView().environmentObject(
            PanelViewModel.preview(query: "email the invoice to sam",
                                   decision: jev(.computerTask, 0.86, ms: 175, risky: true),
                                   mode: .agent,
                                   agentTask: "Email the invoice to Sam",
                                   agentEvents: [
                                    .planned("Open Mail, compose to sam@acme.com, attach ~/Invoices/July.pdf, send."),
                                    .step(index: 1, description: "Composing a new message to sam@acme.com"),
                                    .step(index: 2, description: "Attached July.pdf"),
                                    .needsApproval(id: UUID(), description: "Click “Send”", risk: "Sending an email cannot be undone."),
                                   ],
                                   agentScreenshot: previewScreenshot,
                                   pendingApproval: (UUID(), "Click “Send” in Mail", "Jev: 94% irreversible — the email goes out immediately.")))
    }
}

#Preview("Agent · completed") {
    PreviewBackdrop {
        NaviPanelView().environmentObject(
            PanelViewModel.preview(query: "open chrome and search for jev",
                                   mode: .agent,
                                   agentEvents: [
                                    .planned("Open Chrome and search for Jev."),
                                    .step(index: 1, description: "Opened Google Chrome"),
                                    .step(index: 2, description: "Searched for “jev typesafe”"),
                                    .completed(summary: "Chrome is showing search results for “jev typesafe”."),
                                   ],
                                   statusLine: "Done in 3 steps · 14 s"))
    }
}

#Preview("Agent · failed") {
    PreviewBackdrop {
        NaviPanelView().environmentObject(
            PanelViewModel.preview(query: "open chrome",
                                   mode: .agent,
                                   agentEvents: [.failed("Accessibility permission is required to control other apps.")],
                                   error: "Permission needed: Accessibility. Grant it in System Settings → Privacy & Security."))
    }
}

#Preview("Error banner") {
    PreviewBackdrop {
        NaviPanelView().environmentObject(
            PanelViewModel.preview(query: "what is jev",
                                   results: Array(PanelViewModel.sampleResults[7...7]),
                                   decision: .heuristic(.askQuestion),
                                   error: "Missing API key: TYPESAFE_API_KEY. Add it in Navi → AI Providers."))
    }
}
#endif
