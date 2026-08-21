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

/// Runs one whole engine operation as root behind the standard macOS
/// administrator dialog (one password prompt per operation). Blocking —
/// call it off the main thread. The app never sees the password.
func runPrivileged(_ arguments: [String]) throws {
    let command = ([try engineURL().path] + arguments).map(shellQuoted).joined(separator: " ")
    let source = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
    var errorInfo: NSDictionary?
    guard let script = NSAppleScript(source: source) else {
        throw EngineError.failed("could not build the administrator command")
    }
    if script.executeAndReturnError(&errorInfo) == nil {
        let number = (errorInfo?[NSAppleScript.errorNumber] as? Int) ?? 0
        if number == -128 { throw EngineError.cancelled }
        let message = (errorInfo?[NSAppleScript.errorMessage] as? String)
            ?? "the administrator command failed"
        throw EngineError.failed(message)
    }
}

/// Runs an engine command that needs no privileges (verify, status).
func runEngine(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = try engineURL()
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}
