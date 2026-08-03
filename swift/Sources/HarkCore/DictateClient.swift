import Foundation

/// Agent-side dictation client: POST a WAV to the server's /dictate and get
/// back sanitised text. Ports the response handling of `client/init.lua` and
/// the bounds/transport rules from the native-client design.
///
/// Every response path is bounded and sanitised, not just the 200. The error
/// `detail` string is just as attacker-controlled as a transcript — it reaches
/// an alert rather than the pasteboard, but it must still be capped and cleaned.
public enum DictateError: Error, Equatable {
    case transport(String)           // connection / DNS / timeout
    case unauthorized(String)         // 401
    case unsupportedMediaType(String) // 415
    case badRequest(String)           // 400
    case serviceUnavailable(String)   // 503
    case unexpected(Int, String)      // any other status
    case malformedResponse
    case bodyTooLarge

    public var isTransport: Bool {
        if case .transport = self { return true }
        return false
    }
}

public enum DictateOutcome: Equatable {
    case pasted(String)  // non-empty sanitised text
    case nothing         // 200 with empty / no-alphanumeric text
    case failed(DictateError)
}

public final class DictateClient: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let key: String
    private let maxBodyBytes: Int
    private var session: URLSession!   // set in init after super.init() (needs self as delegate)

    // Per-request state.
    private var accumulated = Data()
    private var response: HTTPURLResponse?
    private var completion: ((Result<(Int, Data), DictateError>) -> Void)?
    private var large = false

    public init(url: URL, key: String, maxBodyBytes: Int = 1 << 20,
                configuration: URLSessionConfiguration? = nil) {
        self.url = url
        self.key = key
        self.maxBodyBytes = maxBodyBytes
        let cfg: URLSessionConfiguration
        if let configuration {
            cfg = configuration
        } else {
            cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 30
        }
        super.init()
        // NOTE: must pass `delegate: self` here — URLSession(configuration:)
        // alone does NOT deliver delegate callbacks, which would leave the
        // semaphore wait in upload() blocked forever.
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        self.session.sessionDescription = "hark-dictate"
    }

    /// Result of a dictation attempt.
    public func dictate(wav: Data) -> DictateOutcome {
        switch upload(wav: wav) {
        case .failure(let e):
            return .failed(e)
        case .success(let pair):
            let (http, body) = pair
            return classify(http: http, body: body)
        }
    }

    // MARK: - Upload with a hard body bound

    private func upload(wav: Data) -> Result<(Int, Data), DictateError> {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = wav
        req.setValue(key, forHTTPHeaderField: "X-Hark-Key")
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")

        // Synchronous bridge: the data task runs on URLSession's own queues, so
        // blocking this caller on a semaphore is safe for the single-request
        // concurrency this client is used for.
        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Int, Data), DictateError> = .failure(.transport("no result"))
        accumulated = Data()
        response = nil
        large = false
        completion = { res in
            result = res
            sem.signal()
        }
        session.dataTask(with: req).resume()
        sem.wait()
        completion = nil
        return result
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                           didReceive data: Data) {
        accumulated.append(data)
        if accumulated.count > maxBodyBytes {
            large = true
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                           didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let completion else { return }
        self.completion = nil
        if large {
            completion(.failure(.bodyTooLarge))
            return
        }
        if let error {
            completion(.failure(.transport(error.localizedDescription)))
            return
        }
        guard let resp = self.response else {
            completion(.failure(.transport("no HTTP response")))
            return
        }
        completion(.success((resp.statusCode, accumulated)))
    }

    // MARK: - Response classification

    private func classify(http: Int, body: Data) -> DictateOutcome {
        if http == 200 {
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let text = obj["text"] as? String else {
                return .failed(.malformedResponse)
            }
            let sanitised = Sanitize.sanitize(text)
            if sanitised.isEmpty { return .nothing }
            return .pasted(sanitised)
        }

        let detail = extractDetail(body)
        switch http {
        case 401: return .failed(.unauthorized(detail))
        case 415: return .failed(.unsupportedMediaType(detail))
        case 400: return .failed(.badRequest(detail))
        case 503: return .failed(.serviceUnavailable(detail))
        default: return .failed(.unexpected(http, detail))
        }
    }

    private func extractDetail(_ body: Data) -> String {
        let raw = String(decoding: body, as: UTF8.self)
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let detail = obj["detail"] as? String else {
            return raw
        }
        return Sanitize.sanitize(detail)
    }
}
