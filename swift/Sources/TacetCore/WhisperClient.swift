import Foundation

/// HTTP client for whisper.cpp's whisper-server, port of `src/tacet/whisper.py`.
///
/// The server holds the model resident; a fresh `whisper-cli` per utterance
/// would reload ~1.5 GB every time. Vocabulary biasing is applied at server
/// startup via `--prompt`, not per request.
public enum WhisperError: Error, CustomStringConvertible {
    case unavailable(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .unavailable(let m): return m
        case .malformed(let m): return "malformed response from whisper-server: \(m)"
        }
    }
}

public struct WhisperClient {
    public let baseURL: String
    public let connectTimeout: Double
    public let transcribeTimeout: Double

    public init(baseURL: String, connectTimeout: Double = 5.0, transcribeTimeout: Double = 60.0) {
        self.baseURL = baseURL
        self.connectTimeout = connectTimeout
        self.transcribeTimeout = transcribeTimeout
    }

    /// POST a WAV to `/inference` as multipart/form-data and return the text.
    /// The SQLite-free hand-rolled multipart is the point of the stdlib build
    /// (issue #4): outbound multipart is one of the few things a library got
    /// right that we now own.
    public func transcribe(wav: Data) async throws -> String {
        let boundary = "TacetBoundary\(UUID().uuidString)"
        let body = Self.makeMultipart(boundary: boundary, wav: wav)

        var req = URLRequest(url: URL(string: baseURL + "/inference")!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = transcribeTimeout
        config.timeoutIntervalForResource = transcribeTimeout

        do {
            let (data, response) = try await URLSession(configuration: config).data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw WhisperError.unavailable("no HTTP response from whisper-server")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw WhisperError.unavailable("whisper-server returned HTTP \(http.statusCode)")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String else {
                throw WhisperError.malformed(
                    String(decoding: data.prefix(512), as: UTF8.self))
            }
            return text
        } catch let e as WhisperError {
            throw e
        } catch {
            throw WhisperError.unavailable("\(error)")
        }
    }

    static func makeMultipart(boundary: String, wav: Data) -> Data {
        var body = Data()
        func appendASCII(_ s: String) { body.append(Data(s.utf8)) }

        appendASCII("--\(boundary)\r\n")
        appendASCII("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        appendASCII("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        appendASCII("\r\n")

        for (name, value) in [("response_format", "json"), ("temperature", "0.0")] {
            appendASCII("--\(boundary)\r\n")
            appendASCII("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            appendASCII(value)
            appendASCII("\r\n")
        }
        appendASCII("--\(boundary)--\r\n")
        return body
    }
}
