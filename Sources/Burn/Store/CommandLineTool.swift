import AppKit
import Foundation

/// Installs the two things that put Burn's numbers where the work is: a `burn` command in `~/.local/bin`
/// (a two-line wrapper around this app's binary), and a Claude Code status-line wrapper that runs whatever status
/// line was there before and adds Burn's segment after it.
enum CommandLineTool {
    static let binDirectory = NSString(string: "~/.local/bin").expandingTildeInPath
    static var toolPath: String { binDirectory + "/burn" }
    static let claudeDirectory = NSString(string: "~/.claude").expandingTildeInPath
    static var wrapperPath: String { claudeDirectory + "/statusline-burn.sh" }
    static var settingsPath: String { claudeDirectory + "/settings.json" }

    /// The app binary the wrapper calls — this one.
    static var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    static var isToolInstalled: Bool { FileManager.default.isExecutableFile(atPath: toolPath) }
    static var isStatuslineInstalled: Bool {
        guard let settings = readSettings(), let line = settings["statusLine"] as? [String: Any],
              let command = line["command"] as? String else { return false }
        return command.contains("statusline-burn.sh")
    }

    /// Writes `~/.local/bin/burn`. Returns the path, or the error to show.
    @discardableResult
    static func installTool() throws -> String {
        try FileManager.default.createDirectory(atPath: binDirectory, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        # Installed by Burn — the app's command-line tool. Reinstall from Settings → General if the app moves.
        exec "\(executable)" cli "$@"

        """
        try script.write(toFile: toolPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolPath)
        return toolPath
    }

    static func removeTool() throws {
        guard let text = try? String(contentsOfFile: toolPath, encoding: .utf8), text.contains("Installed by Burn") || text.contains("Installed by Headroom") else { return }
        try FileManager.default.removeItem(atPath: toolPath)
    }

    /// What `installStatusline` would do, as lines for a dry run or a confirmation.
    static func statuslinePlan() -> [String] {
        let existing = existingStatuslineCommand()
        var lines = ["write \(NSString(string: wrapperPath).abbreviatingWithTildeInPath) — runs " + (existing.map { "`\($0)`" } ?? "nothing else") + ", then adds Burn's segment"]
        lines.append("back up \(NSString(string: settingsPath).abbreviatingWithTildeInPath) to settings.json.burn-bak")
        lines.append("set statusLine.command to `bash \(NSString(string: wrapperPath).abbreviatingWithTildeInPath)` in settings.json")
        return lines
    }

    /// Adds Burn's segment to the Claude Code status line without touching the user's own script.
    static func installStatusline() throws {
        try FileManager.default.createDirectory(atPath: claudeDirectory, withIntermediateDirectories: true)
        let existing = existingStatuslineCommand().flatMap { $0.contains("statusline-burn.sh") ? nil : $0 }
        // If a previous install already points at the wrapper, keep the base command the wrapper recorded.
        let base = existing ?? recordedBaseCommand() ?? ""
        let script = """
        #!/bin/bash
        # Installed by Burn — runs your status line, then adds Burn's segment. Remove the statusLine entry in
        # ~/.claude/settings.json (a backup is beside it) to go back.
        # base: \(base)
        input=$(cat)
        base=""
        if [ -n "\(base)" ]; then base=$(printf '%s' "$input" | \(base) 2>/dev/null); fi
        seg=$(printf '%s' "$input" | "\(executable)" cli statusline 2>/dev/null)
        if [ -n "$base" ] && [ -n "$seg" ]; then printf '%s | %s\\n' "$base" "$seg"
        elif [ -n "$seg" ]; then printf '%s\\n' "$seg"
        else printf '%s\\n' "$base"; fi

        """
        try script.write(toFile: wrapperPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperPath)

        var settings = readSettings() ?? [:]
        if FileManager.default.fileExists(atPath: settingsPath) {
            try? FileManager.default.removeItem(atPath: settingsPath + ".burn-bak")
            try FileManager.default.copyItem(atPath: settingsPath, toPath: settingsPath + ".burn-bak")
        }
        settings["statusLine"] = ["type": "command", "command": "bash \(NSString(string: wrapperPath).abbreviatingWithTildeInPath)"]
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: settingsPath) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func existingStatuslineCommand() -> String? {
        guard let line = readSettings()?["statusLine"] as? [String: Any] else { return nil }
        return (line["command"] as? String)?.trimmingCharacters(in: .whitespaces)
    }

    /// The command a previous wrapper wrapped, from its header comment.
    private static func recordedBaseCommand() -> String? {
        guard let text = try? String(contentsOfFile: wrapperPath, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("# base: ") {
            let base = line.dropFirst("# base: ".count).trimmingCharacters(in: .whitespaces)
            return base.isEmpty ? nil : base
        }
        return nil
    }
}
