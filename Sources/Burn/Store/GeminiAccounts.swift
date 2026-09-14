import Foundation

/// Google accounts signed in through Burn for Gemini (as Antigravity), one credential file each, in the shape the
/// Gemini CLI uses plus `email` and `client`. Kept under Application Support.
enum GeminiAccounts {
    struct Account: Sendable, Hashable {
        var file: URL
        var email: String
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Burn/gemini", isDirectory: true)
    }

    static func all() -> [Account] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = FileManager.default.contents(atPath: file.path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let email = json["email"] as? String else { return nil }
            return Account(file: file, email: email)
        }.sorted { $0.email < $1.email }
    }

    static func account(matching snapshot: AccountSnapshot) -> Account? {
        guard snapshot.providerID == .gemini, let email = snapshot.identity else { return nil }
        return all().first { $0.email == email }
    }

    @discardableResult
    static func save(_ tokens: GoogleLogin.Tokens) throws -> Account {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let slug = tokens.email.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let file = directory.appendingPathComponent("\(String(slug)).json")
        var json: [String: Any] = [
            "email": tokens.email,
            "client": "antigravity",
            "access_token": tokens.accessToken,
            "refresh_token": tokens.refreshToken,
            "expiry_date": Int(tokens.expiresAt.timeIntervalSince1970 * 1000),
            "token_type": "Bearer",
            "scope": GoogleLogin.scopes.joined(separator: " "),
        ]
        if let idToken = tokens.idToken { json["id_token"] = idToken }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return Account(file: file, email: tokens.email)
    }

    /// Forget the account: revoke the refresh token with Google (best effort) and delete the file.
    static func remove(_ account: Account) async {
        if let data = FileManager.default.contents(atPath: account.file.path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let refresh = json["refresh_token"] as? String {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("token=\(refresh)".utf8)
            _ = try? await HTTP.session.data(for: request)
        }
        try? FileManager.default.removeItem(at: account.file)
        Log.write("gemini account removed: \(account.email)")
    }
}
