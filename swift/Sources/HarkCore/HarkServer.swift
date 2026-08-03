import Foundation
import Network

/// The hark service: audio in, transcript out. A stdlib HTTP/1.1 server on the
/// loopback (or a configured private address), replacing FastAPI + uvicorn in
/// `src/hark/app.py` (issue #4). One user, one request at a time — async buys
/// nothing here, so the server is deliberately simple.
///
/// Deliberately contains no business logic — sanitisation and ASR live in
/// `Sanitize` and `WhisperClient`, imported by name so tests can fake them.
/// The server does not inject the transcript anywhere; it returns it in the
/// response and the client pastes it at the cursor.
public enum HarkServerError: Error, CustomStringConvertible {
    case bindFailed(String)
    public var description: String {
        switch self {
        case .bindFailed(let m): return m
        }
    }
}

public struct HTTPRequest {
    public let method: String
    public let target: String
    public let headers: [String: String] // lower-cased keys
    public let body: Data
}

public struct HTTPResponse {
    public let status: Int
    public let contentType: String
    public let body: Data

    public var serialized: Data {
        let reason = Self.reason(for: status)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 415: return "Unsupported Media Type"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

public protocol WhisperTranscribing {
    func transcribe(wav: Data) async throws -> String
}

extension WhisperClient: WhisperTranscribing {}

public final class HarkServer {
    let config: HarkConfig
    let key: String
    let whisper: any WhisperTranscribing
    let logger: Logger

    public init(config: HarkConfig = .load(),
                key: String = KeyFile.ensure(),
                whisper: (any WhisperTranscribing)? = nil,
                logger: Logger = Logger(label: "hark")) {
        self.config = config
        self.key = key
        self.whisper = whisper ?? WhisperClient(baseURL: config.whisperURL,
                                                connectTimeout: config.connectTimeout,
                                                transcribeTimeout: config.transcribeTimeout)
        self.logger = logger
    }

    /// Bind and start serving on a port (default: `config.harkPort`; pass a
    /// port to override, e.g. for tests). Non-blocking — returns the live
    /// listener so callers (or tests) can cancel it. The connection handler is
    /// installed immediately; `serve()` just adds the blocking runloop.
    @discardableResult
    public func start(port: UInt16? = nil) throws -> NWListener {
        let portNumber = port ?? UInt16(config.harkPort)
        guard let p = NWEndpoint.Port(rawValue: portNumber) else {
            throw HarkServerError.bindFailed("invalid port \(portNumber)")
        }
        let listener = try NWListener(using: .tcp, on: p)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.stateUpdateHandler = { [logger] state in
            if case .failed(let e) = state { logger.error("listener failed: \(e)") }
        }
        listener.start(queue: .global(qos: .userInitiated))
        logger.info("hark listening on \(config.bindHost):\(portNumber)")
        return listener
    }

    /// Run until the process is terminated.
    public func serve() throws {
        _ = try start()
        dispatchMain()
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            if case .ready = state {
                self.receiveLoop(conn, buffer: Data())
            }
        }
        conn.start(queue: .global(qos: .default))
    }

    private func receiveLoop(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak conn] data, _, isComplete, error in
            guard let conn else { return }
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }

            if error != nil || isComplete {
                conn.cancel()
                return
            }

            guard let self else { return }
            // Try to complete a request with whatever we have.
            do {
                let (request, consumed) = try HTTPParser.parseComplete(from: buf)
                let response = self.dispatch(request)
                conn.send(content: response.serialized, completion: .contentProcessed { _ in
                    conn.cancel()
                })
                _ = consumed
            } catch HTTPParseError.incomplete {
                // Need more data.
                self.receiveLoop(conn, buffer: buf)
            } catch {
                // Unparseable request: 400.
                let resp = HTTPResponse(status: 400, contentType: "application/json",
                                        body: Data("{\"detail\":\"bad request\"}".utf8))
                conn.send(content: resp.serialized, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }

    // MARK: - Routing

    func dispatch(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.target) {
        case ("GET", "/health"):
            return HTTPResponse(status: 200, contentType: "application/json",
                                body: Data("{\"status\":\"ok\"}".utf8))
        case ("POST", "/dictate"):
            return dictate(request)
        default:
            return jsonError(404, "not found")
        }
    }

    private func dictate(_ request: HTTPRequest) -> HTTPResponse {
        // Authorisation: both checks matter, and each independently defeats the
        // drive-by CSRF (a CORS-simple request needs no preflight). X-Hark-Key
        // and Content-Type audio/wav are both non-safelisted, so requiring them
        // forces a preflight, which fails — no CORS middleware is installed.
        let presented = request.headers["x-hark-key"] ?? ""
        guard ConstantTime.equal(presented, key) else {
            logger.warning("rejected unauthenticated POST /dictate")
            return jsonError(401, "missing or invalid X-Hark-Key")
        }

        // Ignore parameters: `audio/wav; charset=binary` is still audio/wav.
        let mediaType = (request.headers["content-type"] ?? "")
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() ?? ""
        guard mediaType == "audio/wav" else {
            logger.warning("rejected POST /dictate with content-type \(mediaType)")
            return jsonError(415, "expected Content-Type: audio/wav")
        }

        // Parse and validate the wire format: 16 kHz mono 16-bit PCM.
        let info: WAVInfo
        do {
            info = try WAV.parse(request.body)
        } catch let e as WAVError {
            logger.warning("rejected audio: \(e.description)")
            return jsonError(400, formatDetail(for: e))
        } catch {
            return jsonError(400, formatDetail(for: WAVError.notReadable("\(error)")))
        }
        guard info.sampleWidth == 2 else {
            return jsonError(400, formatDetail(for: .unsupportedSampleWidth(info.sampleWidth)))
        }
        guard info.channelCount == 1 else {
            return jsonError(400, "expected mono audio, got \(info.channelCount) channels")
        }
        guard info.sampleRate == 16000 else {
            return jsonError(400, "expected 16 kHz audio, got \(info.sampleRate) Hz")
        }

        // Whisper hallucinates on silence, so it must be caught on the AUDIO.
        let amplitude = WAV.rmsPCM(info.data)
        if amplitude < config.silenceRMSThreshold {
            logger.info("silent audio (rms \(String(format: "%.1f", amplitude)) < \(String(format: "%.1f", config.silenceRMSThreshold))); returning empty transcript")
            return jsonText("")
        }

        let raw = sync {
            try await self.whisper.transcribe(wav: request.body)
        }
        let text: String
        do {
            text = try raw.get()
        } catch {
            logger.error("whisper-server unavailable: \(error)")
            return jsonError(503, "\(error)")
        }

        let sanitised = Sanitize.sanitize(text)
        if !hasAlphanumeric(sanitised) {
            logger.info("transcript has no alphanumerics; returning empty transcript")
            return jsonText("")
        }

        // Log the LENGTH only, never the text — transcripts are private and
        // must never settle into a world-readable file in /tmp.
        logger.info("transcribed \(sanitised.count) chars (rms \(String(format: "%.1f", amplitude)), threshold \(String(format: "%.1f", config.silenceRMSThreshold)))")
        return jsonText(sanitised)
    }

    /// The server's error detail must be branched by cause so a malformed
    /// header from the client does not send users to Microphone settings.
    private func formatDetail(for e: WAVError) -> String {
        switch e {
        case .emptyBody:
            return e.description + ". Check that the client has microphone permission and is sending 16 kHz mono 16-bit PCM WAV."
        default:
            return e.description + ". Expected 16 kHz mono 16-bit PCM WAV."
        }
    }

    private func hasAlphanumeric(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private func jsonText(_ text: String) -> HTTPResponse {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let body = "{\"text\":\"\(escaped)\"}"
        return HTTPResponse(status: 200, contentType: "application/json", body: Data(body.utf8))
    }

    private func jsonError(_ status: Int, _ detail: String) -> HTTPResponse {
        let escaped = detail
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let body = "{\"detail\":\"\(escaped)\"}"
        return HTTPResponse(status: status, contentType: "application/json", body: Data(body.utf8))
    }

    /// Bridge an async call into the sync connection handler. The URLSession
    /// work runs on its own queues so blocking this worker thread is fine for
    /// the single-user concurrency this server is built for.
    private func sync<T>(_ body: @escaping () async throws -> T) -> Result<T, Error> {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error> = .failure(HarkServerError.bindFailed("unreached"))
        Task {
            do { result = .success(try await body()) }
            catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return result
    }
}

// MARK: - Logging shim (kept dependency-free)

public struct Logger {
    let label: String
    func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
    public init(label: String) { self.label = label }
    func write(_ level: String, _ msg: String) {
        let line = "\(timestamp()) \(level) \(label): \(msg)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
    func info(_ msg: String) { write("INFO", msg) }
    func warning(_ msg: String) { write("WARNING", msg) }
    func error(_ msg: String) { write("ERROR", msg) }
}

enum ConstantTime {
    static func equal(_ a: String, _ b: String) -> Bool {
        let aa = Array(a.utf8), bb = Array(b.utf8)
        guard aa.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aa.count { diff |= aa[i] ^ bb[i] }
        return diff == 0
    }
}

enum HTTPParseError: Error {
    case incomplete
    case malformed
}

enum HTTPParser {
    /// Parse a single HTTP/1.1 request if the buffer holds it completely.
    /// Returns (request, bytesConsumed). Throws `.incomplete` if more data is
    /// needed (either the header or the body has not fully arrived).
    static func parseComplete(from data: Data) throws -> (HTTPRequest, Int) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw HTTPParseError.incomplete
        }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            throw HTTPParseError.malformed
        }
        var lines = headerStr.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { throw HTTPParseError.malformed }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        let available = data.count - bodyStart
        guard available >= contentLength else { throw HTTPParseError.incomplete }

        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return (HTTPRequest(method: method, target: target, headers: headers, body: body),
                bodyStart + contentLength)
    }
}
