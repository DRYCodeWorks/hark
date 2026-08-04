import Foundation

/// The shared secret gating POST /dictate. Lives at `~/.config/tacet/key`,
/// mode 600, generated on first server use. Read and trimmed by the client.
///
/// Deliberately not a credential system: one user, one key, one file. On the
/// server the key is generated on first use and persisted so the client can be
/// configured once by reading the file. The file lives outside the repo and is
/// never committed.
public enum KeyFile {
    /// Test-only override so tests don't touch the real `~/.config/tacet/key`.
    public static var pathOverride: URL?

    public static var path: URL {
        if let override = pathOverride {
            return override
        }
        if let env = ProcessInfo.processInfo.environment["TACET_KEY_FILE"] {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tacet/key")
    }

    /// Read and trim the key, or nil if absent/unreadable. A key from the
    /// environment wins over the file, mirroring `config.py`'s `TACET_KEY`.
    public static func load() -> String? {
        if let env = ProcessInfo.processInfo.environment["TACET_KEY"] {
            let trimmed = env.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let data = try? Data(contentsOf: path) else { return nil }
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Generate and persist a key if absent. Directory mode 700, file mode 600
    /// with an exclusive create (a concurrent request cannot clobber ours).
    /// Returns the key.
    @discardableResult
    public static func ensure() -> String {
        if let existing = load() { return existing }
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let key = generateKey()
        let created = FileManager.default.createFile(
            atPath: path.path, contents: Data((key + "\n").utf8),
            attributes: [.posixPermissions: 0o600])
        if created { return key }
        // Lost the race to a concurrent writer; use its key, not ours.
        return load() ?? key
    }

    static func generateKey() -> String {
        // 32 bytes of urandom → URL-safe base64 (≈ 43 chars), like Python's
        // secrets.token_urlsafe(32).
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
