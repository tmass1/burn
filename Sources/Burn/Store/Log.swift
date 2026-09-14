import Foundation

/// Append-only text log in Application Support — the unified log hides accessory-app messages behind privacy
/// filters, and a plain file is what you actually want when a card says something odd.
enum Log {
    nonisolated(unsafe) private static var file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Burn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("burn.log")
    }()

    private static let queue = DispatchQueue(label: "burn.log")
    nonisolated(unsafe) private static var seenKeys = Set<String>()

    /// For conditions that hold on every poll (an ignored keychain item, say): one line per process, not one per minute.
    static func once(_ key: String, _ message: String) {
        let first = queue.sync { seenKeys.insert(key).inserted }
        if first { write(message) }
    }

    /// The command-line tool writes the file but keeps stderr for its own output.
    nonisolated(unsafe) static var quiet = false

    static func write(_ message: String) {
        let line = "\(Date.now.formatted(.iso8601)) \(message)\n"
        if !quiet { NSLog("%@", message) }
        queue.async {
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
            // Keep it small: trim when past ~500 KB.
            if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 500_000,
               let text = try? String(contentsOf: file, encoding: .utf8) {
                let tail = text.split(separator: "\n").suffix(2000).joined(separator: "\n") + "\n"
                try? Data(tail.utf8).write(to: file)
            }
        }
    }
}
