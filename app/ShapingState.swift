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

/// Counts bytes across the parallel measurement downloads and replaces any
/// stream that finishes early, so per-request size limits never cap the test.
private final class ByteCounter: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var total = 0
    private var stopped = false
    var makeTask: (() -> URLSessionDataTask)?

    var snapshot: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        total += data.count
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let halted = stopped
        lock.unlock()
        guard !halted, error == nil, let makeTask else { return }
        makeTask().resume()
    }
}

@MainActor
final class ShapingModel: ObservableObject {
    @Published var state = ShapingState.load()
    @Published var busy = false
    @Published var throughput = "Speed: …"

    private var measuring = false
    private var lastMeasurement: (bps: Int, at: Date, key: String)?

    func refresh() { state = ShapingState.load() }

    /// Fills the menu's Speed line with the connection's available bandwidth:
    /// a ~3-second burst of parallel downloads over a fixed time window (so it
    /// stays quick even under a heavy cap), cached for two minutes unless the
    /// shaping state changed.
    func refreshBandwidth() {
        let key = "\(state.active)|\(state.preset)|\(state.appliedAt)"
        if let last = lastMeasurement, last.key == key,
           Date().timeIntervalSince(last.at) < 120 {
            throughput = "Speed: \(Self.speedText(last.bps))"
            return
        }
        guard !measuring else { return }
        measuring = true
        throughput = "Speed: …"
        Task.detached(priority: .userInitiated) {
            let measured = await Self.measureBandwidth()
            await MainActor.run {
                self.measuring = false
                if let measured {
                    self.lastMeasurement = (measured, Date(), key)
                    self.throughput = "Speed: \(Self.speedText(measured))"
                } else {
                    self.throughput = "Speed: —"
                }
            }
        }
    }

    /// Sums bytes received by three parallel downloads during a 2.5-second
    /// window after a short warm-up, fast.com style. Returns bits per second,
    /// or nil when nothing arrived (offline, or shaping at 100% loss).
    nonisolated static func measureBandwidth() async -> Int? {
        // The endpoint rejects requests much above 50 MB; finished streams are
        // respawned by ByteCounter, so the size only bounds one request.
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=50000000") else {
            return nil
        }
        let counter = ByteCounter()
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: counter, delegateQueue: nil)
        counter.makeTask = { session.dataTask(with: url) }
        defer {
            counter.stop()
            session.invalidateAndCancel()
        }
        for _ in 0..<3 { counter.makeTask?().resume() }
        try? await Task.sleep(nanoseconds: 750_000_000)
        let startBytes = counter.snapshot
        let startTime = Date()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let bytes = counter.snapshot - startBytes
        let elapsed = Date().timeIntervalSince(startTime)
        guard bytes > 0, elapsed > 0 else { return nil }
        return Int(Double(bytes) * 8 / elapsed)
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
