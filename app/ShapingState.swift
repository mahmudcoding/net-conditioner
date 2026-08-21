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
/// Streams answered with an HTTP error (rate limits included) are cancelled
/// without counting the error body and are never respawned, and respawns are
/// capped so a misbehaving endpoint can't be hammered.
private final class ByteCounter: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var total = 0
    private var stopped = false
    private var respawns = 0
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

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        completionHandler((200..<300).contains(status) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        total += data.count
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let halted = stopped || respawns >= 20
        if !halted && error == nil { respawns += 1 }
        lock.unlock()
        guard !halted, error == nil, let makeTask else { return }
        makeTask().resume()
    }
}

@MainActor
final class ShapingModel: ObservableObject {
    @Published var state = ShapingState.load()
    @Published var busy = false
    @Published var throughput = ""

    private var loopSession: URLSession?
    private var loopCounter: ByteCounter?
    private var loopTimer: Timer?
    private var loopTicks = 0
    private var loopUpdates = 0
    private var lastTickBytes = 0
    private var lastTickTime = Date()
    private var panelVisible = false

    func refresh() { state = ShapingState.load() }

    /// The panel shows the connection's available bandwidth and keeps it
    /// fresh while open: three parallel downloads run continuously and the
    /// Speed line updates from the byte delta every two seconds. After a few
    /// refreshes the streams stop so an open panel doesn't download forever;
    /// the last value is kept and reused for the first paint on reopen.
    func panelDidOpen() {
        guard !panelVisible else { return }
        panelVisible = true
        refresh()
        // Never show a stale number: the line stays empty until the current
        // panel session has actually measured something.
        throughput = ""
        startBandwidthLoop()
    }

    func panelDidClose() {
        guard panelVisible else { return }
        panelVisible = false
        stopBandwidthLoop()
    }

    /// Public test files on independent hosts; the loop falls through them
    /// when one stalls or rate-limits, and remembers which one last worked.
    private static let measurementSources = [
        "https://speed.cloudflare.com/__down?bytes=50000000",
        "https://proof.ovh.net/files/100Mb.dat",
        "https://fsn1-speed.hetzner.com/100MB.bin",
    ]
    private var loopSourceIndex = 0
    private var loopInitialSource = 0
    private var preferredSourceIndex = 0

    private func startBandwidthLoop(sourceIndex: Int? = nil) {
        stopBandwidthLoop()
        let index = sourceIndex ?? preferredSourceIndex
        guard index < Self.measurementSources.count,
              let url = URL(string: Self.measurementSources[index]) else {
            return
        }
        loopSourceIndex = index
        if sourceIndex == nil { loopInitialSource = index }
        let counter = ByteCounter()
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: counter, delegateQueue: nil)
        counter.makeTask = { session.dataTask(with: url) }
        loopSession = session
        loopCounter = counter
        loopTicks = 0
        loopUpdates = 0
        lastTickBytes = 0
        lastTickTime = Date()
        for _ in 0..<3 { counter.makeTask?().resume() }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.bandwidthTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        loopTimer = timer
    }

    private func bandwidthTick() {
        guard let counter = loopCounter else { return }
        let now = Date()
        let bytes = counter.snapshot
        let delta = bytes - lastTickBytes
        let elapsed = now.timeIntervalSince(lastTickTime)
        lastTickBytes = bytes
        lastTickTime = now
        loopTicks += 1
        // Header-sized dribbles are not a measurement: error bodies and
        // stalled streams must never register as a (tiny) speed.
        if delta >= 10_000, elapsed > 0 {
            loopUpdates += 1
            preferredSourceIndex = loopSourceIndex
            let bps = Int(Double(delta) * 8 / elapsed)
            throughput = "Speed: \(Self.speedText(bps))"
        }
        // Keep refreshing for as long as the panel is realistically being
        // watched; the one-minute cap stops a forgotten-open panel from
        // downloading forever (reopening starts a fresh measurement).
        if loopTicks >= 30 {
            stopBandwidthLoop()
            return
        }
        // A source that produced essentially nothing by the first tick is
        // refusing or dead — rotate to the next one, at most one full cycle.
        if loopUpdates == 0, bytes < 2_000 {
            let next = (loopSourceIndex + 1) % Self.measurementSources.count
            if next != loopInitialSource {
                startBandwidthLoop(sourceIndex: next)
            } else {
                stopBandwidthLoop()
            }
        }
    }

    private func stopBandwidthLoop() {
        loopTimer?.invalidate()
        loopTimer = nil
        loopCounter?.stop()
        loopSession?.invalidateAndCancel()
        loopCounter = nil
        loopSession = nil
    }

    func applyPreset(_ name: String) { runOperation(["preset", name]) }

    func applyCustom(_ arguments: [String]) { runOperation(["set"] + arguments) }

    func turnOff() { runOperation(["off"]) }

    private func runOperation(_ arguments: [String]) {
        guard !busy else { return }
        busy = true
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do {
                try runPrivileged(arguments)
                failure = nil
            } catch EngineError.cancelled {
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                self.busy = false
                self.refresh()
                // The shape changed, so the displayed bandwidth is stale;
                // re-measure right away if the panel is showing.
                self.throughput = ""
                if self.panelVisible { self.startBandwidthLoop() }
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
