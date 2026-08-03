import Foundation

/// Client-side configuration: which server to dictate to, and with what key.
///
/// Distinct from `HarkConfig`, which describes how the SERVER deploys itself.
/// Conflating them is what left the agent hardcoded to
/// `http://127.0.0.1:\(config.harkPort)/dictate` with the key read from
/// `~/.config/hark/key` — correct for a single machine, and unusable for the
/// two-machine setup this project exists to serve, because on the recording
/// Mac there is no server, no key file, and nothing listening on loopback.
///
/// Worth noting the single-machine case is not automatically loopback either:
/// a server that binds a tailnet address to serve a laptop is NOT reachable at
/// 127.0.0.1, so the machine running the server needs a real client address
/// too.
///
/// Lives at `~/.config/hark/client.json`:
///
///     {
///       "server": "http://100.64.66.46:8911/dictate",
///       "key": "...",
///       "allowPlaintext": true
///     }
public struct ClientConfig {
    public let serverURL: URL
    public let key: String

    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case malformed(String)
        case insecure(String)

        public var description: String {
            switch self {
            case .unreadable(let m), .malformed(let m), .insecure(let m): return m
            }
        }
    }

    /// Test-only override, mirroring `KeyFile.pathOverride`.
    public static var pathOverride: URL?

    /// HARK_CLIENT_CONFIG overrides the path, mirroring the server side's
    /// HARK_CONFIG. Neither FileManager.homeDirectoryForCurrentUser nor
    /// NSHomeDirectory() reliably honours $HOME on macOS — both resolve through
    /// the user database — so `HOME=... hark agent` silently reads the real
    /// config. That produced a round of "passing" policy checks that were all
    /// reading the same live file. An explicit variable is the only honest way
    /// to point this somewhere else.
    public static var path: URL {
        if let pathOverride { return pathOverride }
        if let env = ProcessInfo.processInfo.environment["HARK_CLIENT_CONFIG"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hark/client.json")
    }

    private struct Wire: Decodable {
        let server: String?
        let key: String?
        let allowPlaintext: Bool?
    }

    /// Reads client.json. Falls back to the single-machine defaults — loopback
    /// plus `~/.config/hark/key` — when the file is absent, so an existing
    /// same-machine install keeps working untouched.
    public static func load(defaultPort: Int) throws -> ClientConfig {
        guard let data = try? Data(contentsOf: path) else {
            let url = URL(string: "http://127.0.0.1:\(defaultPort)/dictate")!
            return ClientConfig(serverURL: url, key: KeyFile.load() ?? "")
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw Failure.malformed("\(path.path) is not valid JSON")
        }

        let raw = wire.server ?? "http://127.0.0.1:\(defaultPort)/dictate"
        guard let url = URL(string: raw), let host = url.host, let scheme = url.scheme else {
            throw Failure.malformed("\(path.path): \"\(raw)\" is not a usable URL")
        }

        try validateTransport(url: url, host: host, scheme: scheme,
                              allowPlaintext: wire.allowPlaintext ?? false)

        let key = wire.key ?? KeyFile.load() ?? ""
        guard !key.isEmpty else {
            throw Failure.unreadable(
                "no shared secret: set \"key\" in \(path.path), or place the server's "
                + "~/.config/hark/key on this Mac")
        }
        return ClientConfig(serverURL: url, key: key)
    }

    /// The transport policy from the design doc, enforced rather than assumed:
    ///
    ///   - plain HTTP to numeric loopback is always fine — nothing leaves the host
    ///   - plain HTTP to a numeric IP is a defensible choice on a tailnet, but it
    ///     must be a STATED one, so it needs `allowPlaintext`
    ///   - plain HTTP to a hostname is refused outright. A name resolves through
    ///     something, and "the tailnet is trusted" stops being true the moment
    ///     the name resolves somewhere else. Use the tailnet IP.
    static func validateTransport(url: URL, host: String, scheme: String,
                                  allowPlaintext: Bool) throws {
        guard scheme == "http" else { return } // https needs no argument
        if isLoopback(host) { return }

        guard isNumericIP(host) else {
            throw Failure.insecure(
                "\(path.path): plain HTTP to the hostname \"\(host)\" is not allowed. "
                + "Use the numeric address (a Tailscale MagicDNS name is a hostname), "
                + "or https://")
        }
        guard allowPlaintext else {
            throw Failure.insecure(
                "\(path.path): plain HTTP to \(host) needs \"allowPlaintext\": true. "
                + "Audio and transcripts cross the network unencrypted; on a tailnet "
                + "that is defensible, but it should be a decision you made.")
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    /// IPv4 dotted-quad or anything bracketed/colon-bearing (IPv6). Deliberately
    /// narrow: the question is only "did the user give an address or a name".
    static func isNumericIP(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isNumber) else { return false }
            return Int(p).map { (0...255).contains($0) } ?? false
        }
    }
}
