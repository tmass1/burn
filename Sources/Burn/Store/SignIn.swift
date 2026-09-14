import AppKit
import Foundation

/// Where the vendor CLIs live on this Mac. A GUI app's PATH is nearly empty, so look in the usual homes directly.
enum CLI {
    static let searchDirectories: [String] = [
        "/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.claude/local", "~/.grok/bin", "/usr/bin", "/bin",
    ].map { NSString(string: $0).expandingTildeInPath }

    static func locate(_ name: String) -> URL? {
        for directory in searchDirectories {
            let path = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// The process environment for a CLI: ours, with a real PATH and no colour codes in what we capture.
    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchDirectories + [env["PATH"] ?? ""]).joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        for (key, value) in extra { env[key] = value }
        return env
    }

    struct Result: Sendable {
        var status: Int32
        var output: String
    }

    /// Run to completion, output captured. Only for short commands (status checks, logout).
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]) async -> Result {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return Result(status: -1, output: error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}

/// Claude Code profiles Burn created, one per extra Claude account. Claude Code keys everything — config,
/// keychain item — off `CLAUDE_CONFIG_DIR`, so a profile is just a directory under the home folder.
enum ClaudeProfiles {
    struct Profile: Codable, Hashable, Sendable {
        var path: String
        var email: String?
        var orgID: String?
        /// The keychain service Claude Code created for this directory, learned by diffing items around the login.
        var service: String?

        var displayPath: String { NSString(string: path).abbreviatingWithTildeInPath }
    }

    private static let key = "claudeProfiles"

    static func load() -> [Profile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Profile].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [Profile]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func upsert(_ profile: Profile) {
        var list = load().filter { $0.path != profile.path }
        list.append(profile)
        save(list)
    }

    static func remove(path: String) {
        save(load().filter { $0.path != path })
    }

    static func profile(forService service: String) -> Profile? {
        load().first { $0.service == service }
    }

    /// The profile behind a card: by the keychain service that produced it, else by who is signed in there.
    static func profile(matching snapshot: AccountSnapshot) -> Profile? {
        guard snapshot.providerID == .claude else { return nil }
        let known = KnownAccounts.load()
        if let service = known.first(where: { $0.value.id == snapshot.id })?.key, let byService = profile(forService: service) {
            return byService
        }
        return load().first { profile in
            guard let email = profile.email, email == snapshot.identity else { return false }
            return profile.orgID.map { snapshot.id.hasPrefix("claude:\($0):") } ?? true
        }
    }

    /// `~/.claude-personal`, then `~/.claude-personal-2`, … — the first name nothing is using.
    static func nextDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let taken = Set(load().map(\.path))
        var n = 1
        while true {
            let url = home.appendingPathComponent(n == 1 ? ".claude-personal" : ".claude-personal-\(n)")
            if !taken.contains(url.path), !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}

/// Runs a vendor CLI's login for the user: the CLI opens the browser and waits for the sign-in to come back;
/// Burn shows its output meanwhile and refreshes the cards when it exits. One at a time.
@MainActor
@Observable
final class SignIn {
    static let shared = SignIn()

    struct Job: Identifiable {
        enum Status: Equatable {
            case running
            case succeeded(String)
            case failed(String)
            /// It worked, but it was an account Burn already shows — undone, with the reason.
            case duplicate(String)
        }

        let id = UUID()
        let target: LoginTarget
        var status: Status = .running
        var output = ""
        /// The URL the CLI is waiting on, once it has printed it — for pasting into a private window when the
        /// browser is signed in to the wrong account.
        var loginURL: URL?
        /// The CLI is asking for the authentication code the browser showed (Claude's manual flow, used when its
        /// loopback callback can't run). The user pastes it here; Burn types it into the terminal.
        var awaitingCode = false
    }

    private(set) var job: Job?
    private var process: Process?
    private var terminal: PseudoTerminal?
    private var google: GoogleLogin?
    private var cancelled = false
    private var servicesBefore: Set<String> = []
    private var claudeAccountsBefore: [(email: String, orgID: String)] = []

    var isRunning: Bool {
        if case .running = job?.status { return true }
        return false
    }

    func isRunning(_ target: LoginTarget) -> Bool { isRunning && job?.target == target }

    func failure(for target: LoginTarget) -> String? {
        guard let job, job.target == target, case let .failed(message) = job.status else { return nil }
        return message
    }

    /// `email` pre-fills claude.ai's sign-in page, or pre-selects the account in Google's chooser.
    func start(_ target: LoginTarget, email: String? = nil) {
        guard !isRunning else { return }
        cancelled = false
        var job = Job(target: target)

        if case let .gemini(hint) = target {
            self.job = job
            startGoogle(hint: email?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? hint)
            return
        }

        let executable: URL?
        var arguments: [String]
        var extraEnvironment: [String: String] = [:]
        switch target {
        case let .claude(profile):
            executable = CLI.locate("claude")
            arguments = ["auth", "login", "--claudeai"]
            if let email = email?.trimmingCharacters(in: .whitespaces), !email.isEmpty { arguments += ["--email", email] }
            if let profile {
                try? FileManager.default.createDirectory(atPath: profile, withIntermediateDirectories: true)
                extraEnvironment["CLAUDE_CONFIG_DIR"] = profile
            }
            servicesBefore = Set(Keychain.items(withServicePrefix: ClaudeProvider.servicePrefix).map(\.service))
            claudeAccountsBefore = UsageStore.shared.snapshots
                .filter { $0.providerID == .claude }
                .compactMap { snapshot in snapshot.identity.map { ($0, Self.orgID(fromSnapshotID: snapshot.id)) } }
        case .grok:
            executable = CLI.locate("grok")
            arguments = ["login", "--oauth"]
        case .gemini:
            return   // handled above
        }

        guard let executable else {
            job.status = .failed("\(target.cliName) isn't installed where Burn looked.")
            self.job = job
            return
        }
        self.job = job

        // Both CLIs draw their login screens as terminal UIs and refuse a plain pipe, so the child gets a
        // pseudo-terminal: its end as stdin/stdout/stderr, ours to read from (and to answer "Press Enter").
        guard let pty = PseudoTerminal() else {
            self.job?.status = .failed("Couldn't open a terminal for \(target.cliName).")
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = CLI.environment(extraEnvironment)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = pty.child
        process.standardOutput = pty.child
        process.standardError = pty.child
        pty.master.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = PseudoTerminal.plainText(data)
            Task { @MainActor in self?.receive(text) }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in await self?.finish(status: status) }
        }
        do {
            try process.run()
            pty.childStarted()
            self.process = process
            self.terminal = pty
            Log.write("sign-in started: \(executable.lastPathComponent) \(arguments.joined(separator: " "))")
        } catch {
            self.job?.status = .failed("Couldn't start \(executable.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func receive(_ text: String) {
        guard !text.isEmpty, var job else { return }
        job.output += text
        if job.loginURL == nil,
           let range = job.output.range(of: #"https://\S+/oauth/authorize\S+"#, options: .regularExpression) {
            job.loginURL = URL(string: String(job.output[range]))
        }
        if text.localizedCaseInsensitiveContains("paste code here") || text.localizedCaseInsensitiveContains("invalid code") {
            job.awaitingCode = true
        }
        self.job = job
        // The CLIs pause on a keypress after a successful login; a user would press Enter, so do.
        if text.localizedCaseInsensitiveContains("press enter") { terminal?.send("\r") }
    }

    /// Type the browser's authentication code into the waiting CLI.
    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, !trimmed.isEmpty else { return }
        terminal?.send(trimmed + "\n")
        job?.awaitingCode = false
        Log.write("sign-in: authentication code submitted")
    }

    private static func orgID(fromSnapshotID id: String) -> String {
        let parts = id.split(separator: ":")
        return parts.count >= 3 ? String(parts[1]) : ""
    }

    func cancel() {
        guard isRunning else { return }
        cancelled = true
        process?.terminate()
        google?.cancel()
    }

    // MARK: - Google (in-process)

    /// Google's sign-in for Gemini: Burn runs the browser round-trip itself, keeps the tokens in a file of its
    /// own, and the provider picks the account up on the refresh that follows.
    private func startGoogle(hint: String?) {
        let login = GoogleLogin()
        google = login
        let existing = Set(UsageStore.shared.snapshots.filter { $0.providerID == .gemini }.compactMap(\.identity))
        Log.write("sign-in started: google (gemini)\(hint.map { " as \($0)" } ?? "")")
        Task { @MainActor in
            defer { google = nil }
            do {
                let tokens = try await login.run(loginHint: hint) { [weak self] url in
                    self?.job?.loginURL = url
                    self?.job?.output += "Opening Google's sign-in…\n\(url.absoluteString)\n"
                }
                if existing.contains(tokens.email) {
                    job?.status = .duplicate("That signed in as \(tokens.email) — a Gemini account Burn already shows. Pick a different account in Google's chooser next time.")
                    Log.write("sign-in duplicate: \(tokens.email)")
                    return
                }
                try GeminiAccounts.save(tokens)
                Preferences.shared.restore(key: ProviderID.gemini.rawValue)   // a whole-provider removal from before would hide it
                job?.status = .succeeded("Signed in as \(tokens.email)")
                Log.write("sign-in succeeded: gemini \(tokens.email)")
                Task { await UsageStore.shared.refresh() }
            } catch {
                job?.status = .failed(cancelled ? "Cancelled." : error.localizedDescription)
                Log.write("sign-in failed: gemini — \(error.localizedDescription)")
            }
        }
    }

    func dismiss() {
        guard !isRunning else { return }
        job = nil
    }

    private func finish(status: Int32) async {
        process = nil
        terminal?.close()
        terminal = nil
        guard var job, job.status == .running else { return }
        let tail = job.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(2).joined(separator: " ")

        if cancelled {
            job.status = .failed("Cancelled.")
        } else if status == 0 {
            switch job.target {
            case let .claude(profile):
                let identity = await Self.claudeIdentity(profile: profile)
                // A brand-new profile that came back as an account already on a card: claude.ai signed in whoever the
                // browser was signed in as. Undo it rather than let the provider fold it into the existing card.
                if let profile, let identity, !ClaudeProfiles.load().contains(where: { $0.path == profile }),
                   claudeAccountsBefore.contains(where: { $0.email == identity.email && $0.orgID == (identity.orgID ?? "") }) {
                    await discard(profilePath: profile, service: Set(Keychain.items(withServicePrefix: ClaudeProvider.servicePrefix).map(\.service)).subtracting(servicesBefore).first)
                    job.status = .duplicate("That signed in as \(identity.email) — the account Burn already shows, because claude.ai authorizes whichever account your browser is signed in to. Sign out at claude.ai first, or paste the sign-in link into a private window next time.")
                    Log.write("sign-in duplicate: \(identity.email); profile discarded")
                    self.job = job
                    return
                }
                if let profile {
                    let after = Set(Keychain.items(withServicePrefix: ClaudeProvider.servicePrefix).map(\.service))
                    var record = ClaudeProfiles.load().first { $0.path == profile } ?? ClaudeProfiles.Profile(path: profile)
                    if let identity { record.email = identity.email; record.orgID = identity.orgID }
                    if let created = after.subtracting(servicesBefore).first { record.service = created }
                    ClaudeProfiles.upsert(record)
                }
                job.status = .succeeded(identity.map { "Signed in as \($0.email)" } ?? "Signed in")
            case .grok:
                job.status = .succeeded("Signed in to Grok")
            case .gemini:
                break
            }
            Log.write("sign-in succeeded: \(job.target)")
            Task { await UsageStore.shared.refresh() }
        } else {
            job.status = .failed(tail.isEmpty ? "The sign-in didn't complete (exit \(status))." : tail)
            Log.write("sign-in failed (\(status)): \(tail)")
        }
        self.job = job
    }

    /// Who is signed in to a profile, from `claude auth status --json`.
    private static func claudeIdentity(profile: String?) async -> (email: String, orgID: String?)? {
        guard let claude = CLI.locate("claude") else { return nil }
        let env = CLI.environment(profile.map { ["CLAUDE_CONFIG_DIR": $0] } ?? [:])
        let result = await CLI.run(claude, ["auth", "status", "--json"], environment: env)
        guard result.status == 0,
              let start = result.output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(result.output[start...].utf8)) as? [String: Any],
              json["loggedIn"] as? Bool == true,
              let email = json["email"] as? String else { return nil }
        return (email, json["orgId"] as? String)
    }

    // MARK: - Removing a profile

    /// Forgets a Google account Burn signed in itself: revokes the token and deletes its file.
    func removeGemini(_ account: GeminiAccounts.Account) async {
        await GeminiAccounts.remove(account)
        await UsageStore.shared.refresh()
    }

    /// Signs Claude Code out of a Burn-created profile (which deletes its keychain item) and removes the folder.
    func removeProfile(_ profile: ClaudeProfiles.Profile) async {
        await discard(profilePath: profile.path, service: profile.service)
        ClaudeProfiles.remove(path: profile.path)
        await UsageStore.shared.refresh()
    }

    private func discard(profilePath: String, service: String?) async {
        if let claude = CLI.locate("claude") {
            let env = CLI.environment(["CLAUDE_CONFIG_DIR": profilePath])
            let result = await CLI.run(claude, ["auth", "logout"], environment: env)
            Log.write("profile logout \(NSString(string: profilePath).abbreviatingWithTildeInPath): exit \(result.status)")
        }
        if let service {
            // Belt and braces: the item is what makes a card, so make sure it is gone even if logout balked.
            _ = try? Keychain.delete(service: service)
        }
        try? FileManager.default.removeItem(atPath: profilePath)
    }
}

/// A pty pair. The child end goes to the subprocess as its terminal; the master end is what we read and type into.
final class PseudoTerminal {
    let master: FileHandle
    let child: FileHandle
    private let masterFD: Int32
    private var childFD: Int32

    init?() {
        let fd = posix_openpt(O_RDWR | O_NOCTTY)
        guard fd >= 0, grantpt(fd) == 0, unlockpt(fd) == 0, let name = ptsname(fd) else { return nil }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else { Darwin.close(fd); return nil }
        // Terminal UIs lay out against the reported size; without one they get zero columns.
        // Wide, so a terminal UI never wraps the sign-in URL across lines (it is several hundred characters).
        var size = winsize(ws_row: 32, ws_col: 2000, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, 0x8008_7467 /* TIOCSWINSZ */, &size)
        masterFD = fd
        childFD = slave
        master = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        child = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    }

    /// Once the child holds its own copy, ours must go, or reads on the master never see the end.
    func childStarted() {
        if childFD >= 0 { Darwin.close(childFD); childFD = -1 }
    }

    func send(_ text: String) {
        _ = text.utf8CString.withUnsafeBufferPointer { buffer in
            write(masterFD, buffer.baseAddress, buffer.count - 1)
        }
    }

    func close() {
        master.readabilityHandler = nil
        childStarted()
        Darwin.close(masterFD)
    }

    /// What the user would have read: escape sequences and carriage returns stripped.
    static func plainText(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        for pattern in [
            "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", // OSC: window title and the like
            "\u{1B}\\[[0-9;?<>=]*[ -/]*[@-~]",             // CSI: cursor moves, modes, colours
            "\u{1B}[()][A-Za-z0-9]",                        // charset selection
            "\u{1B}[0-9=><]",                               // save/restore cursor, keypad modes
        ] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "\r", with: "")
        return text
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
