import Foundation

/// LaunchAgent install/uninstall for the daily lock — port of src/main/launch-agent.js.
/// Uses the same label as the Electron version.
enum LaunchAgentInstaller {
    static let label = "com.dualnback.lock"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static func escapeXml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func buildPlist(programArguments: [String]) -> String {
        let args = programArguments
            .map { "    <string>\(escapeXml($0))</string>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
        \(args)
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <dict>
            <key>SuccessfulExit</key>
            <false/>
          </dict>
          <key>ProcessType</key>
          <string>Interactive</string>
        </dict>
        </plist>
        """
    }

    /// launchctl failures are often benign (bootstrap when already loaded,
    /// bootout when not loaded), so errors are logged and ignored.
    private static func launchctl(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("launchctl \(args.joined(separator: " ")) failed: \(error)")
        }
    }

    static func install() {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let file = plistURL
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? buildPlist(programArguments: [exe, "--autostart"])
            .write(to: file, atomically: true, encoding: .utf8)
        launchctl(["bootstrap", "gui/\(getuid())", file.path])
    }

    /// Delete the plist BEFORE bootout: bootout SIGTERMs this very process,
    /// and the quit policy checks isInstalled to decide whether quitting is allowed.
    static func uninstall() {
        try? FileManager.default.removeItem(at: plistURL)
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
    }
}
