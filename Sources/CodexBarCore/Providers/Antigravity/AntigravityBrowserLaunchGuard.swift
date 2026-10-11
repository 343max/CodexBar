import Foundation

/// Stops a background `agy` print probe from opening a browser.
///
/// Print mode treats any failed silent sign-in as "not logged in" and execs
/// `open` (or `xdg-open`) from `PATH` to start Google OAuth. That happens when the
/// token refresh hits a network error, when the Keychain read times out, and when
/// termination interrupts the Keychain read. `agy` 1.3.3 has no flag to disable this,
/// and `SSH_TTY` would also switch it to file token storage, so the probe shadows
/// both commands with failing stubs. Successful reports never exec them.
enum AntigravityBrowserLaunchGuard {
    private static let commandNames = ["open", "xdg-open"]

    static func install(into environment: [String: String]) throws -> (environment: [String: String], directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-agy-no-browser-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let stub = "#!/bin/sh\nexit 1\n"
            for name in self.commandNames {
                let url = directory.appendingPathComponent(name)
                try stub.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        var environment = environment
        environment["PATH"] = [directory.path, environment["PATH"]]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ":")
        return (environment, directory)
    }
}
