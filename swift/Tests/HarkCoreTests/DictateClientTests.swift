import XCTest
@testable import HarkCore

/// Unit tests for DictateClient's synchronous HTTP client: response
/// classification and transport/body-bounds hardening. Uses MiniHTTPServer as
/// a mock backend, so no real hark server is needed.
final class DictateClientTests: XCTestCase {

    // MARK: - Helpers

    /// Run a single dictate round-trip against a mock server responding with
    /// `status`/`body` for every request, returning the client's outcome.
    private func dictate(status: Int, body: String, maxBodyBytes: Int = 1 << 20)
        -> DictateOutcome
    {
        let server = try! MiniHTTPServer { _ in (status, Data(body.utf8)) }
        server.start()
        defer { server.stop() }

        let client = DictateClient(
            url: URL(string: "http://127.0.0.1:\(server.port)/dictate")!,
            key: "k",
            maxBodyBytes: maxBodyBytes)
        return client.dictate(wav: WAVFixtures.loudWAV())
    }

    // MARK: - 200 response classification

    func test200EmptyReturnsNothing() {
        let outcome = dictate(status: 200, body: #"{"text":""}"#)
        XCTAssertEqual(outcome, .nothing)
    }

    func test200TextSanitised() {
        let outcome = dictate(status: 200, body: #"{"text":"  hi\n there "}"#)
        XCTAssertEqual(outcome, .pasted("hi there"))
    }

    func test200MalformedJSON() {
        let outcome = dictate(status: 200, body: "not json")
        XCTAssertEqual(outcome, .failed(.malformedResponse))
    }

    // MARK: - Status-code → error classification

    func test401() {
        let outcome = dictate(status: 401, body: #"{"detail":"missing or invalid X-Hark-Key"}"#)
        XCTAssertEqual(outcome, .failed(.unauthorized("missing or invalid X-Hark-Key")))
    }

    func test415() {
        let outcome = dictate(status: 415, body: #"{"detail":"expected Content-Type: audio/wav"}"#)
        XCTAssertEqual(outcome, .failed(.unsupportedMediaType("expected Content-Type: audio/wav")))
    }

    func test400() {
        let outcome = dictate(status: 400, body: #"{"detail":"bad wav"}"#)
        XCTAssertEqual(outcome, .failed(.badRequest("bad wav")))
    }

    func test503() {
        let outcome = dictate(status: 503, body: #"{"detail":"down"}"#)
        XCTAssertEqual(outcome, .failed(.serviceUnavailable("down")))
    }

    func testUnexpectedStatus() {
        let outcome = dictate(status: 418, body: #"{"detail":"teapot"}"#)
        XCTAssertEqual(outcome, .failed(.unexpected(418, "teapot")))
    }

    // MARK: - Hardening

    func testBodyTooLarge() {
        // Tiny cap so the delegate's accumulated-body bound trips mid-download.
        let outcome = dictate(
            status: 200,
            body: #"{"text":"a very long transcript that definitely exceeds the cap"}"#,
            maxBodyBytes: 16)
        XCTAssertEqual(outcome, .failed(.bodyTooLarge))
    }

    func testTransportRefused() {
        // A free port with nothing listening → connection refused → transport.
        let port = TestSupport.freePort()
        let client = DictateClient(
            url: URL(string: "http://127.0.0.1:\(port)/dictate")!,
            key: "k")
        let outcome = client.dictate(wav: WAVFixtures.loudWAV())
        if case .failed(let e) = outcome {
            XCTAssertTrue(e.isTransport, "expected a transport error, got \(e)")
        } else {
            XCTFail("expected .failed transport error, got \(outcome)")
        }
    }
}
