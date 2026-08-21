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
        let name: String
        if !preset.isEmpty && downBps > 0 && downBps == upBps {
            name = "\(Self.rate(downBps))/s"
        } else if preset.isEmpty {
            name = "custom shape"
        } else {
            name = preset
        }
        let scope = hosts.isEmpty ? "" : " → \(hosts.joined(separator: ", "))"
        return "Active: \(name)\(scope)"
    }

    var detail: String {
        guard active else { return "" }
        var parts: [String] = []
        if downBps > 0 && downBps == upBps {
            // A symmetric cap is already the headline; don't repeat it here.
        } else {
            if downBps > 0 { parts.append("\(Self.rate(downBps)) down") }
            if upBps > 0 { parts.append("\(Self.rate(upBps)) up") }
        }
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
    @Published var throughput = "↓ …   ↑ …"

    private var sampler: Timer?
    private var lastSample: (time: Date, rx: UInt64, tx: UInt64)?

    func refresh() { state = ShapingState.load() }

    /// Live current-traffic readout for the menu, sampled from the network
    /// interface counters once a second — no test downloads involved. The
    /// timer runs in the .common run-loop modes so it keeps firing while the
    /// menu is open (menu tracking blocks the default mode and the main
    /// dispatch queue).
    func startSampling() {
        stopSampling()
        if let counters = Self.readInterfaceCounters() {
            lastSample = (Date(), counters.rx, counters.tx)
        }
        throughput = "↓ …   ↑ …"
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    func stopSampling() {
        sampler?.invalidate()
        sampler = nil
        lastSample = nil
    }

    private func sampleTick() {
        guard let counters = Self.readInterfaceCounters() else { return }
        let now = Date()
        defer { lastSample = (now, counters.rx, counters.tx) }
        guard let last = lastSample else { return }
        let dt = now.timeIntervalSince(last.time)
        guard dt > 0.2 else { return }
        // A 32-bit interface counter can wrap; a shrinking total reads as 0.
        let rx = counters.rx >= last.rx ? counters.rx - last.rx : 0
        let tx = counters.tx >= last.tx ? counters.tx - last.tx : 0
        let down = Int(Double(rx) * 8 / dt)
        let up = Int(Double(tx) * 8 / dt)
        throughput = "↓ \(Self.speedText(down))   ↑ \(Self.speedText(up))"
    }

    nonisolated static func readInterfaceCounters() -> (rx: UInt64, tx: UInt64)? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        defer { freeifaddrs(addrs) }
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var pointer = addrs
        while let entry = pointer {
            let ifa = entry.pointee
            pointer = ifa.ifa_next
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard String(cString: ifa.ifa_name) != "lo0" else { continue }
            guard let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            rx &+= UInt64(data.pointee.ifi_ibytes)
            tx &+= UInt64(data.pointee.ifi_obytes)
        }
        return (rx, tx)
    }

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

    nonisolated static func speedText(_ bps: Int) -> String {
        if bps >= 10_000_000 { return "\(Int((Double(bps) / 1_000_000).rounded())) Mbit/s" }
        if bps >= 1_000_000 { return String(format: "%.1f Mbit/s", Double(bps) / 1_000_000) }
        return "\(Int((Double(bps) / 1_000).rounded())) kbit/s"
    }

    static func alert(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
