import Sparkle
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: ShapingModel
    let updaterController: SPUStandardUpdaterController
    @Environment(\.openWindow) private var openWindow

    private static let presets: [(id: String, title: String)] = [
        ("edge", "EDGE — 240 kbit, 400 ms"),
        ("3g", "3G — 780 kbit, 100 ms"),
        ("lte", "LTE — 50 Mbit, 50 ms"),
        ("dsl", "DSL — 2 Mbit down, 256 kbit up"),
        ("very-bad", "Very Bad — 1 Mbit, 500 ms, 10% loss"),
        ("loss-8", "Packet Loss 8% (upload)"),
        ("loss-15", "Packet Loss 15% (upload)"),
        ("blackout", "Blackout — 100% loss"),
    ]

    var body: some View {
        Text(model.state.summary)
            .onAppear { model.refresh() }
        if model.state.active && !model.state.detail.isEmpty {
            Text(model.state.detail)
        }
        Divider()
        ForEach(Self.presets, id: \.id) { preset in
            Button(marked(preset.id, preset.title)) { model.applyPreset(preset.id) }
        }
        Button("Custom…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "custom")
        }
        Divider()
        Button("Turn Off") { model.turnOff() }
            .disabled(!model.state.active)
        Button("Check Connection…") { model.verify() }
        Divider()
        Button("Check for Updates…") { updaterController.checkForUpdates(nil) }
        Button("Quit Net Conditioner") { NSApplication.shared.terminate(nil) }
    }

    private func marked(_ id: String, _ title: String) -> String {
        model.state.active && model.state.preset == id ? "● \(title)" : title
    }
}
