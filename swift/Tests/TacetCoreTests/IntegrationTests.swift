import XCTest
import Network
@testable import TacetCore

/// Real-socket end-to-end tests against the HTTP server: bind an actual
/// NWListener on a free port, then drive it with real URLSession requests
/// (not direct `dispatch()` calls, which ServerTests already covers).
final class IntegrationTests: XCTestCase {

    /// Strong reference to the in-process server so it isn't deallocated mid-test:
    /// TacetServer's connection handler holds `[weak self]`, so dropping the server
    /// (as returning only the listener would) makes every accepted connection die —
    /// the socket then times out. Release in tearDown.
    private var server: TacetServer?

    override func tearDown() {
        server = nil
        super.tearDown()
    }

    /// Build and start a TacetServer on `port`, returning the live listener.
    private func startServer(port: UInt16,
                             whisper: (any WhisperTranscribing)? = nil,
                             key: String = "testkey") throws -> NWListener {
        let server = TacetServer(config: TacetConfig(tacetPort: Int(port)),
                                key: key,
                                whisper: whisper ?? StubWhisper(.success("hello world")),
                                logger: Logger(label: "test"))
        self.server = server
        return try server.start(port: port)
    }

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

    func testHealthOverRealSocket() async throws {
        let port = TestSupport.freePort()
        let listener = try startServer(port: port)
        defer { listener.cancel() }
        XCTAssertTrue(waitForHealth(port: port))

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/health")!)
        let http = try XCTUnwrap(resp as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(TestSupport.bodyText(data).contains("ok"))
    }

    func testAuthOverRealSocket() async throws {
        let port = TestSupport.freePort()
        let listener = try startServer(port: port)
        defer { listener.cancel() }
        XCTAssertTrue(waitForHealth(port: port))

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/dictate")!)
        req.httpMethod = "POST"
        req.setValue("wrong", forHTTPHeaderField: "X-Tacet-Key")
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.httpBody = WAVFixtures.silenceWAV()

        let (_, resp) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(resp as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 401)
    }

    func testSilenceOverRealSocket() async throws {
        let port = TestSupport.freePort()
        let listener = try startServer(port: port)
        defer { listener.cancel() }
        XCTAssertTrue(waitForHealth(port: port))

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/dictate")!)
        req.httpMethod = "POST"
        req.setValue("testkey", forHTTPHeaderField: "X-Tacet-Key")
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.httpBody = WAVFixtures.silenceWAV()

        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(resp as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(TestSupport.bodyText(data), "{\"text\":\"\"}")
    }

    func testTranscriptOverRealSocket() async throws {
        let port = TestSupport.freePort()
        let listener = try startServer(port: port,
                                       whisper: StubWhisper(.success("  hello\n world ")))
        defer { listener.cancel() }
        XCTAssertTrue(waitForHealth(port: port))

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/dictate")!)
        req.httpMethod = "POST"
        req.setValue("testkey", forHTTPHeaderField: "X-Tacet-Key")
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.httpBody = WAVFixtures.loudWAV()

        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(resp as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(TestSupport.bodyText(data).contains("hello world"))
    }
}
