import Sparkle
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: ShapingModel
    let updaterController: SPUStandardUpdaterController

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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.state.summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(model.state.active ? Color.accentColor : .secondary)
                if model.state.active && !model.state.detail.isEmpty {
                    Text(model.state.detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 6)
            .padding(.bottom, 7)

            PanelDivider()
            ForEach(Self.presets, id: \.id) { preset in
                PanelRow(
                    title: preset.title,
                    checked: model.state.active && model.state.preset == preset.id
                ) {
                    model.applyPreset(preset.id)
                }
            }

            PanelDivider()
            PanelRow(title: "Turn Off", enabled: model.state.active) { model.turnOff() }

            PanelDivider()
            PanelRow(title: "Check for Updates…") { updaterController.checkForUpdates(nil) }
            PanelRow(title: "Quit Net Conditioner") { NSApplication.shared.terminate(nil) }
        }
        .padding(6)
        .frame(width: 230)
        .background(PanelVisibility(model: model))
    }
}

private struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 9).padding(.vertical, 4)
    }
}

/// A native-menu-feeling row: full-width hover highlight in the accent
/// color, a trailing checkmark for the active tier, dimmed when disabled.
private struct PanelRow: View {
    let title: String
    var checked = false
    var enabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .fontWeight(checked ? .semibold : .regular)
                Spacer(minLength: 12)
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering && enabled ? Color.accentColor : Color.clear)
            )
            .foregroundColor(hovering && enabled ? .white : .primary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 && enabled }
    }
}
