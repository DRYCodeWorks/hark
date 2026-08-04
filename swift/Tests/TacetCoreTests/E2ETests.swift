import XCTest
@testable import TacetCore

/// Full client→server→whisper path over REAL networking on all three hops.
/// The only fake is the whisper backend (a MiniHTTPServer), not the agent
/// client or the tacet server.
final class E2ETests: XCTestCase {

    /// Poll GET /health over a real socket until it returns 200 (server up).
    private func waitForHealth(port: UInt16) -> Bool {
        TestSupport.waitUntil(timeout: 5.0) {
            guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
            var ok = false
            let sem = DispatchSemaphore(value: 0)
            var req = URLRequest(url: url)
            req.timeoutInterval = 2
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 { ok = true }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 2.0)
            return ok
        }
    }

    func testFullDictationRoundTrip() async throws {
        // 1. Fake whisper-server: answer /inference multipart POST.
        let whisper = try MiniHTTPServer(responder: { _ in
            (200, Data("{\"text\":\"hello  world\"}".utf8))
        })
        whisper.start()
        defer { whisper.stop() }

        // 2. Real tacet server pointed at the fake whisper.
        let tacetPort = TestSupport.freePort()
        let server = TacetServer(
            config: TacetConfig(tacetPort: Int(tacetPort), whisperPort: Int(whisper.port)),
            key: "e2ekey",
            whisper: WhisperClient(baseURL: "http://127.0.0.1:\(whisper.port)"),
            logger: Logger(label: "test"))
        let listener = try server.start(port: tacetPort)
        defer { listener.cancel() }
        XCTAssertTrue(waitForHealth(port: tacetPort))

        // 3. Real agent client → server → fake whisper → back.
        let client = DictateClient(
            url: URL(string: "http://127.0.0.1:\(tacetPort)/dictate")!,
            key: "e2ekey")
        let outcome = client.dictate(wav: WAVFixtures.loudWAV())

        // 4. Server sanitises "hello  world" → "hello world".
        XCTAssertEqual(outcome, .pasted("hello world"))
        XCTAssertEqual(whisper.requestCount, 1)
    }

    func testE2ESilenceReturnsNothing() async throws {
        // Fake whisper-server (never reached on silence).
        let whisper = try MiniHTTPServer(responder: { _ in
            (200, Data("{\"text\":\"\"}".utf8))
        })
        whisper.start()
        defer { whisper.stop() }

        // Real tacet server pointed at the fake whisper.
        let tacetPort = TestSupport.freePort()
        let server = TacetServer(
            config: TacetConfig(tacetPort: Int(tacetPort), whisperPort: Int(whisper.port)),
            key: "e2ekey",
            whisper: WhisperClient(baseURL: "http://127.0.0.1:\(whisper.port)"),
            logger: Logger(label: "test"))
        let listener = try server.start(port: tacetPort)
        defer { listener.cancel() }
        XCTAssertTrue(waitForHealth(port: tacetPort))

        // Silent audio short-circuits before whisper → .nothing.
        let client = DictateClient(
            url: URL(string: "http://127.0.0.1:\(tacetPort)/dictate")!,
            key: "e2ekey")
        let outcome = client.dictate(wav: WAVFixtures.silenceWAV())

        XCTAssertEqual(outcome, .nothing)
        XCTAssertEqual(whisper.requestCount, 0)
    }
}
