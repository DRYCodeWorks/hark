import Foundation

/// Server deployment configuration — a port of `src/hark/config.py`.
///
/// Defaults describe the single-machine setup: bind to loopback, expose
/// nothing. `~/.config/hark/config.toml` (outside the repo) overrides, exactly
/// as it does for the Python server. A missing file is the ordinary case; a
/// malformed one raises rather than silently falling back to defaults (that
/// could bind the service somewhere the user did not ask for).
public struct HarkConfig {
    public var bindHost: String            // server.bind, default 127.0.0.1
    public var harkPort: Int               // server.port, default 8911
    public var whisperHost: String         // always 127.0.0.1 (not configurable)
    public var whisperPort: Int            // whisper.port, default 8910
    public var modelPath: String           // whisper.model
    public var vocabPrompt: String         // whisper.prompt
    public var silenceRMSThreshold: Double // audio.silence_rms_threshold, default 150.0
    public var transcribeTimeout: Double   // 60
    public var connectTimeout: Double      // 5

    public init(bindHost: String = "127.0.0.1",
                harkPort: Int = 8911,
                whisperPort: Int = 8910,
                modelPath: String = "~/.local/share/whisper-cpp/ggml-large-v3-turbo.bin",
                vocabPrompt: String = "",
                silenceRMSThreshold: Double = 150.0,
                transcribeTimeout: Double = 60.0,
                connectTimeout: Double = 5.0) {
        self.bindHost = bindHost
        self.harkPort = harkPort
        self.whisperHost = "127.0.0.1"
        self.whisperPort = whisperPort
        self.modelPath = modelPath
        self.vocabPrompt = vocabPrompt
        self.silenceRMSThreshold = silenceRMSThreshold
        self.transcribeTimeout = transcribeTimeout
        self.connectTimeout = connectTimeout
    }

    public static var configFile: URL {
        if let env = ProcessInfo.processInfo.environment["HARK_CONFIG"] {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hark/config.toml")
    }

    public static func load() -> HarkConfig {
        var cfg = HarkConfig()
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else {
            return cfg
        }
        do {
            let parsed = try MiniTOML.parse(text)
            if let s = parsed.section("server") {
                cfg.bindHost = s.string("bind") ?? cfg.bindHost
                cfg.harkPort = s.int("port") ?? cfg.harkPort
            }
            if let w = parsed.section("whisper") {
                cfg.whisperPort = w.int("port") ?? cfg.whisperPort
                cfg.modelPath = w.string("model") ?? cfg.modelPath
                cfg.vocabPrompt = w.string("prompt") ?? cfg.vocabPrompt
            }
            if let a = parsed.section("audio") {
                cfg.silenceRMSThreshold = a.double("silence_rms_threshold") ?? cfg.silenceRMSThreshold
            }
        } catch {
            fatalError("malformed hark config at \(configFile.path): \(error)")
        }
        return cfg
    }

    public var whisperURL: String { "http://\(whisperHost):\(whisperPort)" }
}

// MARK: - Minimal TOML subset parser

/// Parses just the shape `config.example.toml` uses: `[section]` headers,
/// `key = value` pairs (string / integer / float / boolean), `#` comments.
/// Unknown keys and sections are ignored so a config written for the Python
/// server keeps working. Values that do not parse raise, never silently drop.
struct MiniTOML {
    struct Section {
        let name: String
        var values: [String: String] = [:]
        func string(_ key: String) -> String? { values[key] }
        func int(_ key: String) -> Int? {
            guard let v = values[key], let i = Int(v) else { return nil }
            return i
        }
        func double(_ key: String) -> Double? {
            guard let v = values[key] else { return nil }
            if let i = Int(v) { return Double(i) }
            return Double(v)
        }
    }
    var sections: [String: Section] = [:]

    func section(_ name: String) -> Section? { sections[name] }

    static func parse(_ text: String) throws -> MiniTOML {
        var result = MiniTOML()
        var current: String = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                result.sections[current] = Section(name: current)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                throw TOMLError.malformed(line)
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result.sections[current, default: Section(name: current)].values[key] = value
        }
        return result
    }
}

enum TOMLError: Error, CustomStringConvertible {
    case malformed(String)
    var description: String { "malformed TOML line: \(self)" }
}
