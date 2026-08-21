import AppKit
import Foundation

enum EngineError: LocalizedError {
    case notBundled
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notBundled: return "The netcond engine is missing from the app bundle."
        case .cancelled: return nil
        case .failed(let message): return message
        }
    }
}

func engineURL() throws -> URL {
    guard let url = Bundle.main.url(forResource: "netcond", withExtension: nil) else {
        throw EngineError.notBundled
    }
    return url
}

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func appleScriptQuoted(_ value: String) -> String {
    "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// True when the narrow sudoers rule lets this user drive the shaping tools
/// without a password — then no dialog is ever needed.
func passwordlessShapingAvailable() -> Bool {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    probe.arguments = ["-n", "/usr/sbin/dnctl", "list"]
    probe.standardInput = FileHandle.nullDevice
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    do { try probe.run() } catch { return false }
    probe.waitUntilExit()
    return probe.terminationStatus == 0
}

/// Runs one whole engine operation with root rights: silently through the
/// sudoers rule when it is installed, otherwise behind the standard macOS
/// administrator dialog (one password prompt per operation). Blocking —
/// call it off the main thread. The app never sees the password.
func runPrivileged(_ arguments: [String]) throws {
    if passwordlessShapingAvailable() {
        try runEngineAsUser(arguments)
        return
    }
    let command = ([try engineURL().path] + arguments).map(shellQuoted).joined(separator: " ")
    try runAdminShell(command)
}

/// The engine as the plain user; its internal sudo calls succeed without
/// prompting thanks to the sudoers rule.
private func runEngineAsUser(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = try engineURL()
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    _ = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let message = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw EngineError.failed(message.isEmpty ? "the shaping command failed" : message)
    }
}

/// One shell command as root behind the admin dialog.
func runAdminShell(_ command: String) throws {
    let source = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
    var errorInfo: NSDictionary?
    guard let script = NSAppleScript(source: source) else {
        throw EngineError.failed("could not build the administrator command")
    }
    // executeAndReturnError's return value is non-optional here; failure is
    // signalled solely through the error dictionary.
    _ = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
        let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
        if number == -128 { throw EngineError.cancelled }
        let message = (errorInfo[NSAppleScript.errorMessage] as? String)
            ?? "the administrator command failed"
        throw EngineError.failed(message)
    }
}

let sudoersRulePath = "/etc/sudoers.d/netcond-tools"

/// Installs the narrow sudoers rule (one last password prompt); afterwards
/// shaping changes never ask again.
func installPasswordFreeRule() throws {
    let user = shellQuoted(NSUserName())
    try runAdminShell(
        "printf '%s ALL=(root) NOPASSWD: /usr/sbin/dnctl, /sbin/pfctl\\n' \(user)"
        + " > \(sudoersRulePath) && chmod 440 \(sudoersRulePath)"
        + " && /usr/sbin/visudo -c -f \(sudoersRulePath)"
    )
}

func removePasswordFreeRule() throws {
    try runAdminShell("rm -f \(sudoersRulePath)")
}

