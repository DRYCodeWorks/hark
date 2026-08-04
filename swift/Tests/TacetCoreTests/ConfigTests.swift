import XCTest
@testable import TacetCore

final class ConfigTests: XCTestCase {
    func testDefaultsWhenNoConfig() {
        let cfg = TacetConfig()
        XCTAssertEqual(cfg.bindHost, "127.0.0.1")
        XCTAssertEqual(cfg.tacetPort, 8911)
        XCTAssertEqual(cfg.whisperPort, 8910)
        XCTAssertEqual(cfg.silenceRMSThreshold, 150.0)
        XCTAssertEqual(cfg.whisperURL, "http://127.0.0.1:8910")
    }

    func testTOMLParsing() throws {
        let text = """
        # comment
        [server]
        bind = "192.168.1.5"
        port = 9000

        [whisper]
        port = 9100
        prompt = "terms, jargon"

        [audio]
        silence_rms_threshold = 200.0
        """
        let parsed = try MiniTOML.parse(text)
        let server = parsed.section("server")
        XCTAssertEqual(server?.string("bind"), "192.168.1.5")
        XCTAssertEqual(server?.int("port"), 9000)
        XCTAssertEqual(parsed.section("whisper")?.int("port"), 9100)
        XCTAssertEqual(parsed.section("whisper")?.string("prompt"), "terms, jargon")
        XCTAssertEqual(parsed.section("audio")?.double("silence_rms_threshold"), 200.0)
    }

    func testMalformedTOMLThrows() {
        XCTAssertThrowsError(try MiniTOML.parse("this has no equals\n[server]\nport"))
    }
}
