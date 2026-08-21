import Sparkle
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: ShapingModel
    let updaterController: SPUStandardUpdaterController
    @Environment(\.openWindow) private var openWindow

    private static let presets: [(id: String, title: String)] = [
        ("100kbit", "100 kbit/s"),
        ("250kbit", "250 kbit/s"),
        ("500kbit", "500 kbit/s"),
        ("1mbit", "1 Mbit/s"),
        ("2mbit", "2 Mbit/s"),
        ("5mbit", "5 Mbit/s"),
        ("10mbit", "10 Mbit/s"),
        ("25mbit", "25 Mbit/s"),
        ("50mbit", "50 Mbit/s"),
    ]

    var body: some View {
        Text(model.state.summary)
            .onAppear {
                model.refresh()
                model.refreshBandwidth()
            }
        Text(model.throughput)
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
        Divider()
        Button("Check for Updates…") { updaterController.checkForUpdates(nil) }
        Button("Quit Net Conditioner") { NSApplication.shared.terminate(nil) }
    }

    private func marked(_ id: String, _ title: String) -> String {
        model.state.active && model.state.preset == id ? "● \(title)" : title
    }
}
