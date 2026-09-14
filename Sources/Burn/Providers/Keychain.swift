import Foundation
import Security

/// Claude Code stores its OAuth credentials as generic-password items written through `/usr/bin/security`
/// (`add-generic-password -U … -X <hex>`), so that binary is the trusted app on each item's ACL.
/// Going through the same binary for reads and writes means no "Allow access?" dialogs, ever.
/// Enumeration uses the Security framework directly: attribute queries never touch the secret, so no ACL applies.
enum Keychain {
    struct Item: Sendable, Hashable {
        var service: String
        var account: String
        var modified: Date?
    }

    /// All generic-password items whose service name starts with `prefix`, newest first.
    static func items(withServicePrefix prefix: String) -> [Item] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> Item? in
            guard let service = row[kSecAttrService as String] as? String, service.hasPrefix(prefix) else { return nil }
            let account = row[kSecAttrAccount as String] as? String ?? ""
            return Item(service: service, account: account, modified: row[kSecAttrModificationDate as String] as? Date)
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    static func readString(service: String, account: String? = nil) throws -> String {
        var arguments = ["find-generic-password", "-s", service]
        if let account { arguments += ["-a", account] }
        let out = try run(arguments + ["-w"])
        return out.trimmingCharacters(in: .newlines)
    }

    /// Overwrites the item's data in place (`-U`), keeping Claude Code's own account/service naming.
    static func write(service: String, account: String, string: String) throws {
        let hex = Data(string.utf8).map { String(format: "%02x", $0) }.joined()
        _ = try run(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
    }

    /// Removes an item outright — only for profiles Burn created itself.
    static func delete(service: String) throws {
        _ = try run(["delete-generic-password", "-s", service])
    }

    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProviderError.notSignedIn(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: outData, as: UTF8.self)
    }
}
