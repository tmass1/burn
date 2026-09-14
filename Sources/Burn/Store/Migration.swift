import Foundation

/// The app was called Headroom until 2.0. The first launch as Burn takes over what Headroom kept — its Application
/// Support folder (snapshots, history, spend, the log, the Gemini sign-ins) and its defaults domain (every preference,
/// the hotkey recording, the Claude profile registry, the launchers) — so nothing has to be set up twice. Launch at
/// login is the one thing that cannot come across: macOS registers it per bundle, so it is switched on again from
/// Settings. Runs before anything else touches disk: `Log`, `UsageStore` and `Preferences` all create their files
/// lazily.
enum Migration {
    static let oldBundleID = "com.tommymassaro.headroom"
    static let flag = "migratedFromHeadroom"

    static func runIfNeeded() {
        var notes: [String] = []
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("Headroom", isDirectory: true)
        let new = base.appendingPathComponent("Burn", isDirectory: true)
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) {
            do {
                try fm.moveItem(at: old, to: new)
                let oldLog = new.appendingPathComponent("headroom.log")
                if fm.fileExists(atPath: oldLog.path) {
                    try? fm.moveItem(at: oldLog, to: new.appendingPathComponent("burn.log"))
                }
                notes.append("moved Application Support/Headroom to Burn")
            } catch {
                notes.append("could not move Application Support/Headroom: \(error.localizedDescription)")
            }
        }

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: flag) {
            if let theirs = defaults.persistentDomain(forName: oldBundleID), !theirs.isEmpty {
                for (key, value) in theirs where defaults.object(forKey: key) == nil {
                    defaults.set(value, forKey: key)
                }
                notes.append("copied \(theirs.count) settings from \(oldBundleID)")
            }
            defaults.set(true, forKey: flag)
        }
        for note in notes { Log.write("migration: \(note)") }
    }
}
