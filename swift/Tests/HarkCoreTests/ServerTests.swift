import XCTest
@testable import HarkCore

/// A stub transcription backend so server tests need no whisper-server.
final class StubWhisper: WhisperTranscribing {
    var result: Result<String, Error>
    init(_ result: Result<String, Error>) { self.result = result }
    func transcribe(wav: Data) async throws -> String {
        try result.get()
    }
}

final class ServerTests: XCTestCase {
    private var server: HarkServer!

    override func setUp() {
        super.setUp()
        server = HarkServer(config: HarkConfig(), key: "testkey",
                            whisper: StubWhisper(.success("hello world")),
                            logger: Logger(label: "test"))
    }

    private func dictate(body: Data = WAVFixtures.loudWAV(),
                         contentType: String = "audio/wav",
                         key: String = "testkey") -> HTTPResponse {
        // Header keys must be lower-cased exactly as HTTPParser produces them;
        // dispatch() looks up by lower-cased key.
        let req = HTTPRequest(method: "POST", target: "/dictate",
                              headers: ["x-hark-key": key, "content-type": contentType],
                              body: body)
        return server.dispatch(req)
    }

    private func bodyText(_ resp: HTTPResponse) -> String {
        String(decoding: resp.body, as: UTF8.self)
    }

    func testHealth() {
        let resp = server.dispatch(HTTPRequest(method: "GET", target: "/health",
                                               headers: [:], body: Data()))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(bodyText(resp), "{\"status\":\"ok\"}")
    }

    func testWrongKeyUnauthorized() {
        let resp = dictate(key: "wrong")
        XCTAssertEqual(resp.status, 401)
        XCTAssertTrue(bodyText(resp).contains("X-Hark-Key"))
    }

    func testWrongContentType() {
        let resp = dictate(contentType: "text/plain")
        XCTAssertEqual(resp.status, 415)
    }

    func testContentTypeParamsAccepted() {
        // audio/wav; charset=binary is still audio/wav.
        let resp = dictate(contentType: "audio/wav; charset=binary")
        XCTAssertEqual(resp.status, 200)
    }

    func testSilenceReturnsEmptyWithoutTranscribing() {
        // A zero-RMS body must short-circuit to {"text":""}, never reach whisper.
        let resp = dictate(body: WAVFixtures.silenceWAV())
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(bodyText(resp), "{\"text\":\"\"}")
    }

    func testTranscriptIsSanitisedAndCollapsed() {
        server = HarkServer(config: HarkConfig(), key: "testkey",
                            whisper: StubWhisper(.success("  hello\n  world  ")),
                            logger: Logger(label: "test"))
        let resp = dictate()
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(bodyText(resp), "{\"text\":\"hello world\"}")
    }

    func testNoAlphanumericReturnsEmpty() {
        server = HarkServer(config: HarkConfig(), key: "testkey",
                            whisper: StubWhisper(.success("!!!" )),
                            logger: Logger(label: "test"))
        let resp = dictate()
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(bodyText(resp), "{\"text\":\"\"}")
    }

    func testWhisperUnavailableIs503() {
        server = HarkServer(config: HarkConfig(), key: "testkey",
                            whisper: StubWhisper(.failure(WhisperError.unavailable("boom"))),
                            logger: Logger(label: "test"))
        let resp = dictate()
        XCTAssertEqual(resp.status, 503)
    }

    func testWrongSampleRateIs400() {
        let fortyOne = WAVFixtures.rawWAV(sampleRate: 44100,
                                          data: WAVFixtures.pcm([100]))
        let resp = dictate(body: fortyOne)
        XCTAssertEqual(resp.status, 400)
        XCTAssertTrue(bodyText(resp).contains("16 kHz"))
    }

    func testStereoIs400() {
        let stereo = WAVFixtures.rawWAV(channels: 2, data: WAVFixtures.pcm([100, 100]))
        let resp = dictate(body: stereo)
        XCTAssertEqual(resp.status, 400)
        XCTAssertTrue(bodyText(resp).contains("mono"))
    }

    func testEmptyBody400NamesMicrophone() {
        let resp = dictate(body: Data())
        XCTAssertEqual(resp.status, 400)
        XCTAssertTrue(bodyText(resp).lowercased().contains("microphone"))
    }
}
