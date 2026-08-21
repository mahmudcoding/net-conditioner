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
        VStack(alignment: .leading, spacing: 2) {
            Text(model.state.summary)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            if !model.throughput.isEmpty {
                Text(model.throughput)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            if model.state.active && !model.state.detail.isEmpty {
                Text(model.state.detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Divider().padding(.vertical, 4)
            ForEach(Self.presets, id: \.id) { preset in
                row(marked(preset.id, preset.title)) { model.applyPreset(preset.id) }
            }
            row("Custom…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "custom")
            }
            Divider().padding(.vertical, 4)
            row("Turn Off") { model.turnOff() }
                .disabled(!model.state.active)
            Divider().padding(.vertical, 4)
            row("Check for Updates…") { updaterController.checkForUpdates(nil) }
            row("Quit Net Conditioner") { NSApplication.shared.terminate(nil) }
        }
        .padding(10)
        .frame(width: 220)
        .onAppear {
            model.refresh()
            model.panelDidOpen()
        }
        .onDisappear { model.panelDidClose() }
    }

    private func row(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }

    private func marked(_ id: String, _ title: String) -> String {
        model.state.active && model.state.preset == id ? "● \(title)" : title
    }
}
