import AppKit
import Foundation

/// Mirror of ~/.netcond/state, the KEY=VALUE file the engine writes. The app
/// reads it instead of probing pf/dnctl because live probes require root and
/// a passive status refresh must never raise a password dialog.
struct ShapingState: Equatable {
    var active = false
    var preset = ""
    var downBps = 0
    var upBps = 0
    var rttMs = 0
    var lossUpPct = 0.0
    var lossDownPct = 0.0
    var hosts: [String] = []
    var appliedAt = ""

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".netcond/state")
    }

    static func load() -> ShapingState {
        var state = ShapingState()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return state }
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            switch key {
            case "ACTIVE": state.active = value == "1"
            case "PRESET": state.preset = value
            case "DOWN_BPS": state.downBps = Int(value) ?? 0
            case "UP_BPS": state.upBps = Int(value) ?? 0
            case "RTT_MS": state.rttMs = Int(value) ?? 0
            case "LOSS_UP_PCT": state.lossUpPct = Double(value) ?? 0
            case "LOSS_DOWN_PCT": state.lossDownPct = Double(value) ?? 0
            case "HOSTS": state.hosts = value.split(separator: " ").map(String.init)
            case "APPLIED_AT": state.appliedAt = value
            default: break
            }
        }
        return state
    }

    var summary: String {
        guard active else { return "Shaping off" }
        let name = preset.isEmpty ? "custom shape" : preset.uppercased()
        let scope = hosts.isEmpty ? "" : " → \(hosts.joined(separator: ", "))"
        return "Active: \(name)\(scope)"
    }

    var detail: String {
        guard active else { return "" }
        var parts: [String] = []
        if downBps > 0 { parts.append("\(Self.rate(downBps)) down") }
        if upBps > 0 { parts.append("\(Self.rate(upBps)) up") }
        if rttMs > 0 { parts.append("+\(rttMs) ms RTT") }
        if lossUpPct > 0 { parts.append("\(Self.percent(lossUpPct))% loss up") }
        if lossDownPct > 0 { parts.append("\(Self.percent(lossDownPct))% loss down") }
        return parts.joined(separator: " · ")
    }

    static func rate(_ bps: Int) -> String {
        if bps >= 1_000_000 { return String(format: "%g Mbit", Double(bps) / 1_000_000) }
        if bps >= 1_000 { return String(format: "%g kbit", Double(bps) / 1_000) }
        return "\(bps) bit"
    }

    static func percent(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

@MainActor
final class ShapingModel: ObservableObject {
    @Published var state = ShapingState.load()
    @Published var busy = false

    func refresh() { state = ShapingState.load() }

    func applyPreset(_ name: String) { runOperation(["preset", name]) }

    func applyCustom(_ arguments: [String]) { runOperation(["set"] + arguments) }

    func turnOff() { runOperation(["off"]) }

    private func runOperation(_ arguments: [String]) {
        guard !busy else { return }
        busy = true
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do { try runPrivileged(arguments) }
            catch EngineError.cancelled {}
            catch { failure = error.localizedDescription }
            await MainActor.run {
                self.busy = false
                self.refresh()
                if let failure { Self.alert(title: "Net Conditioner", text: failure) }
            }
        }
    }

    func verify() {
        guard !busy else { return }
        busy = true
        Task.detached(priority: .userInitiated) {
            let output: String
            do { output = try runEngine(["verify", "--probes", "30"]) }
            catch { output = "The connection check failed to run: \(error.localizedDescription)" }
            await MainActor.run {
                self.busy = false
                Self.alert(title: "Connection Check", text: output)
            }
        }
    }

    static func alert(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
