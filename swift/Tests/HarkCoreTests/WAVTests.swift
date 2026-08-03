import XCTest
@testable import HarkCore

/// Helpers to craft WAV fixtures inline (no fixtures on disk in CI).
enum WAVFixtures {
    static func rawWAV(sampleRate: Int = 16000, channels: Int = 1,
                       bits: Int = 16, data: Data) -> Data {
        var out = Data()
        func a(_ s: String) { out.append(Data(s.utf8)) }
        func le16(_ v: Int) { out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)) }
        func le32(_ v: Int) {
            out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
        }
        let blockAlign = channels * (bits / 8)
        let byteRate = sampleRate * blockAlign
        a("RIFF"); le32(36 + data.count); a("WAVE")
        a("fmt "); le32(16); le16(1); le16(channels); le32(sampleRate)
        le32(byteRate); le16(blockAlign); le16(bits)
        a("data"); le32(data.count); out.append(data)
        return out
    }

    /// Little-endian s16 PCM from samples.
    static func pcm(_ samples: [Int16]) -> Data {
        var d = Data()
        for s in samples {
            let u = UInt16(bitPattern: s)
            d.append(UInt8(u & 0xFF))
            d.append(UInt8((u >> 8) & 0xFF))
        }
        return d
    }

    static func silenceWAV(frames: Int = 8000) -> Data {
        rawWAV(data: pcm([Int16](repeating: 0, count: frames)))
    }

    static func loudWAV(amplitude: Int16 = 1000, frames: Int = 8000) -> Data {
        rawWAV(data: pcm([Int16](repeating: amplitude, count: frames)))
    }
}

final class WAVTests: XCTestCase {
    func testRMSOfConstantAmplitude() throws {
        let wav = WAVFixtures.loudWAV(amplitude: 2000)
        XCTAssertEqual(try WAV.rms(wav), 2000.0, accuracy: 1.0)
    }
    func testRMSOfSilenceIsZero() throws {
        XCTAssertEqual(try WAV.rms(WAVFixtures.silenceWAV()), 0.0)
    }
    func testEmptyBodyThrowsEmpty() {
        XCTAssertThrowsError(try WAV.rms(Data())) { err in
            XCTAssertEqual(err as? WAVError, .emptyBody)
        }
    }
    func testNotAWAVThrows() {
        XCTAssertThrowsError(try WAV.rms(Data("not a wav at all".utf8)))
    }
    func testWrongSampleWidthRejected() {
        // 24-bit samples must be refused loudly, not mis-scaled.
        let wav = WAVFixtures.rawWAV(bits: 24, data: Data(repeating: 0, count: 600))
        XCTAssertThrowsError(try WAV.rms(wav)) { err in
            guard case WAVError.unsupportedSampleWidth(let w) = err else {
                return XCTFail("expected unsupportedSampleWidth, got \(err)")
            }
            XCTAssertEqual(w, 3)
        }
    }
    func testParseIgnoresPreDataChunks() throws {
        // hello.wav uses a LIST/INFO chunk before data; ensure it still parses.
        let wav = WAVFixtures.rawWAV(data: WAVFixtures.pcm([10, 20]))
        let info = try WAV.parse(wav)
        XCTAssertEqual(info.sampleWidth, 2)
        XCTAssertEqual(info.channelCount, 1)
        XCTAssertEqual(info.sampleRate, 16000)
    }
    func testHeaderBuilderRoundTrips() throws {
        let payload = WAVFixtures.pcm([1, -1, 300, -300])
        let wav = WAV.header16kMono16Bit(dataByteCount: payload.count) + payload
        let info = try WAV.parse(wav)
        XCTAssertEqual(info.sampleWidth, 2)
        XCTAssertEqual(info.channelCount, 1)
        XCTAssertEqual(info.sampleRate, 16000)
        XCTAssertEqual(info.data.count, payload.count)
    }
}
