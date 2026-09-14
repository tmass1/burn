import AppKit
import Foundation

/// From "which account has room" to using it: a `claude-<account>` command per Claude account Burn knows —
/// a shell shim that sets `CLAUDE_CONFIG_DIR` to the account's profile and execs Claude Code — and a way to open a
/// terminal already running it. The default Claude login is never switched; the shims make it explicit instead.
@MainActor
enum Launchers {
    static let binDirectory = CommandLineTool.binDirectory
    static let marker = "Installed by Burn"

    enum TerminalApp: String, CaseIterable, Sendable {
        case terminal, iterm, warp, ghostty, copy

        var title: String {
            switch self {
            case .terminal: "Terminal"
            case .iterm: "iTerm2"
            case .warp: "Warp"
            case .ghostty: "Ghostty"
            case .copy: "Copy the command instead"
            }
        }
        var bundleID: String? {
            switch self {
            case .terminal: "com.apple.Terminal"
            case .iterm: "com.googlecode.iterm2"
            case .warp: "dev.warp.Warp-Stable"
            case .ghostty: "com.mitchellh.ghostty"
            case .copy: nil
            }
        }
        var isInstalled: Bool {
            guard let bundleID else { return true }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }
        /// Terminal and iTerm run a `.command` file handed to them; the others take the command from the clipboard.
        var runsCommandFiles: Bool { self == .terminal || self == .iterm }
    }

    // MARK: - Shims

    /// "Studio Team" → `claude-studio-team`; a second account with the same name gets `-2`.
    static func command(for snapshot: AccountSnapshot) -> String {
        let base = "claude-" + slug(Preferences.shared.label(for: snapshot))
        let taken = Preferences.shared.installedLaunchers.filter { $0.key != snapshot.id }.values
        var name = base
        var n = 2
        while taken.contains(name) { name = "\(base)-\(n)"; n += 1 }
        return name
    }

    static func slug(_ label: String) -> String {
        let lowered = label.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let parts = lowered.split { !$0.isLetter && !$0.isNumber }
        let joined = parts.joined(separator: "-")
        return joined.isEmpty ? "account" : joined
    }

    static func isInstalled(_ snapshot: AccountSnapshot) -> Bool {
        guard let name = Preferences.shared.installedLaunchers[snapshot.id] else { return false }
        return FileManager.default.isExecutableFile(atPath: binDirectory + "/" + name)
    }

    static func canLaunch(_ snapshot: AccountSnapshot) -> Bool {
        snapshot.providerID == .claude && (ClaudeProfiles.profile(matching: snapshot) != nil || isDefaultProfile(snapshot))
    }

    static func isDefaultProfile(_ snapshot: AccountSnapshot) -> Bool {
        KnownAccounts.load()[ClaudeProvider.defaultService]?.id == snapshot.id
    }

    /// Writes the shim and remembers it. The `claude` path is resolved now and written absolutely, so the shim
    /// works in shells with a different PATH; the default profile's shim is just a named alias.
    @discardableResult
    static func install(_ snapshot: AccountSnapshot) throws -> String {
        guard canLaunch(snapshot) else { throw LauncherError.notLaunchable }
        guard let claude = CLI.locate("claude") else { throw LauncherError.claudeMissing }
        let name = command(for: snapshot)
        let path = binDirectory + "/" + name
        let profile = ClaudeProfiles.profile(matching: snapshot)?.path
        var lines = ["#!/bin/sh", "# \(marker) — Claude Code as \(snapshot.identity ?? Preferences.shared.label(for: snapshot))"]
        if let profile { lines.append("export CLAUDE_CONFIG_DIR=\"\(profile)\"") }
        lines.append("exec \"\(claude.path)\" \"$@\"")
        try FileManager.default.createDirectory(atPath: binDirectory, withIntermediateDirectories: true)
        // A rename: drop the old shim first.
        if let old = Preferences.shared.installedLaunchers[snapshot.id], old != name { removeFile(binDirectory + "/" + old) }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        Preferences.shared.installedLaunchers[snapshot.id] = name
        Log.write("launcher installed: \(name) → \(profile ?? "default profile")")
        return name
    }

    static func remove(_ snapshot: AccountSnapshot) {
        guard let name = Preferences.shared.installedLaunchers[snapshot.id] else { return }
        removeFile(binDirectory + "/" + name)
        Preferences.shared.installedLaunchers.removeValue(forKey: snapshot.id)
        Log.write("launcher removed: \(name)")
    }

    static func removeByID(_ id: String) {
        guard let name = Preferences.shared.installedLaunchers[id] else { return }
        removeFile(binDirectory + "/" + name)
        Preferences.shared.installedLaunchers.removeValue(forKey: id)
    }

    /// Every launchable account without a working shim.
    static func missing(in snapshots: [AccountSnapshot]) -> [AccountSnapshot] {
        snapshots.filter { canLaunch($0) && !isInstalled($0) }
    }

    static var binOnPath: Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init).contains(binDirectory)
    }

    /// Only files this app wrote are ever deleted (under either of its names).
    private static func removeFile(_ path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), text.contains(marker) || text.contains("Installed by Headroom") else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Opening a terminal

    /// Opens a terminal running the account's command (installing the shim first if needed), or copies the command
    /// when that is the preference or the app can't take a script. Returns what to tell the user, if anything.
    static func open(_ snapshot: AccountSnapshot) -> String? {
        let name: String
        do { name = isInstalled(snapshot) ? Preferences.shared.installedLaunchers[snapshot.id]! : try install(snapshot) }
        catch { return (error as? LauncherError)?.message ?? error.localizedDescription }
        let app = Preferences.shared.terminalApp
        guard app != .copy, app.isInstalled else { return copy(name) }
        guard app.runsCommandFiles, let bundleID = app.bundleID,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            if let bundleID = app.bundleID, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            }
            return copy(name)
        }
        // A .command file is what Terminal (and iTerm) run when handed one — no Apple Events, no typing into windows.
        let dir = UsageStore.supportDirectory.appendingPathComponent("launch", isDirectory: true)
        let file = dir.appendingPathComponent("\(name).command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "#!/bin/sh\n# \(marker)\ncd \"$HOME\"\nexec \"\(binDirectory)/\(name)\"\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch { return copy(name) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: config) { _, error in
            if let error { Task { @MainActor in Log.write("launcher: could not open \(app.title): \(error.localizedDescription)") } }
        }
        return nil
    }

    private static func copy(_ name: String) -> String {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
        return "Copied `\(name)` — paste it into a terminal."
    }

    // MARK: - The other providers

    /// Where the other providers' accounts live: the app to open, when there is one.
    static func vendorApp(for provider: ProviderID) -> (bundleID: String, name: String)? {
        switch provider {
        case .codex: ("com.openai.chat", "ChatGPT")
        case .cursor: ("com.todesktop.230313mzl4w4u92", "Cursor")
        case .gemini: ("com.google.antigravity", "Antigravity")
        case .claude, .grok, .copilot: nil
        }
    }

    static func openVendorApp(for provider: ProviderID) -> Bool {
        guard let app = vendorApp(for: provider) else { return false }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        if provider == .gemini, FileManager.default.fileExists(atPath: GeminiProvider.appPath) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: GeminiProvider.appPath), configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return false
    }

    enum LauncherError: Error {
        case notLaunchable, claudeMissing
        var message: String {
            switch self {
            case .notLaunchable: "Only Claude accounts with a profile get a command."
            case .claudeMissing: "Claude Code isn't installed where Burn looked (claude on PATH, Homebrew, ~/.local/bin)."
            }
        }
    }
}
