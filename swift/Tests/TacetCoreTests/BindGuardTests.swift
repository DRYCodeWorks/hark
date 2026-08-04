import XCTest
@testable import TacetCore

/// The bind guard and the body cap.
///
/// Both were missing from the Swift server while present in the Python one it
/// replaces, and both are the kind of thing that looks fine until someone
/// looks at `lsof`.
final class BindGuardTests: XCTestCase {

    /// tacet's response is pasted into whatever has focus, so an endpoint on
    /// every interface lets anyone who can route here choose what gets typed.
    /// Enforced in the Python server since #6; porting the server without it
    /// silently undid that.
    func testWildcardBindsAreRefused() throws {
        for host in ["0.0.0.0", "::", "", "  "] {
            let cfg = TacetConfig(bindHost: host, tacetPort: 8999)
            let server = TacetServer(config: cfg)
            XCTAssertThrowsError(try server.start(), "bind \(host.debugDescription) must be refused") { error in
                guard case TacetServerError.bindFailed(let message) = error else {
                    return XCTFail("expected bindFailed, got \(error)")
                }
                XCTAssertTrue(message.contains("every network interface"),
                              "the message must say why, not just that it failed")
            }
        }
    }

    func testAPrivateAddressIsAccepted() throws {
        let cfg = TacetConfig(bindHost: "127.0.0.1", tacetPort: 8998)
        let listener = try TacetServer(config: cfg).start()
        defer { listener.cancel() }
        XCTAssertNotNil(listener)
    }

    /// The body is parsed before routing, so before the key is checked. Without
    /// a cap an unauthenticated request can make the server buffer whatever
    /// Content-Length it claims.
    func testAnOversizedBodyIsRefusedBeforeItIsBuffered() {
        let claimed = maxBodyBytes + 1
        let head = "POST /dictate HTTP/1.1\r\nContent-Type: audio/wav\r\nContent-Length: \(claimed)\r\n\r\n"
        XCTAssertThrowsError(try HTTPParser.parseComplete(from: Data(head.utf8))) { error in
            XCTAssertEqual(error as? HTTPParseError, .tooLarge,
                           "a huge Content-Length must be refused, not awaited")
        }
    }

    func testABodyAtTheLimitIsNotRefusedOnSize() {
        // At the cap it is incomplete (the body has not arrived), NOT tooLarge.
        let head = "POST /dictate HTTP/1.1\r\nContent-Type: audio/wav\r\nContent-Length: \(maxBodyBytes)\r\n\r\n"
        XCTAssertThrowsError(try HTTPParser.parseComplete(from: Data(head.utf8))) { error in
            XCTAssertEqual(error as? HTTPParseError, .incomplete)
        }
    }

    func testTheCapLeavesRoomForRealUtterances() {
        // 16 kHz mono s16 = 32000 B/s. A hold-to-talk utterance is seconds.
        XCTAssertGreaterThan(maxBodyBytes, 32000 * 60, "under a minute of audio would be too tight")
    }
}
