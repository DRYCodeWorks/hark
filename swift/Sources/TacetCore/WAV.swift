import Foundation

/// Audio energy measurement + WAV parsing — a port of `src/tacet/audio.py`.
///
/// Whisper hallucinates on silence (digital silence -- " Thank you.", faint
/// noise -- " ."), so the gate has to sit on the AUDIO, before transcription.
/// The server measures RMS and refuses to send quiet audio to whisper at all.
///
/// The documented wire format is **16 kHz, mono, 16-bit signed PCM, one `data`
/// chunk**. The threshold in Config is calibrated on the signed-16-bit scale,
/// so any other sample width would be silently mis-scaled against it — refuse
/// loudly instead.
public enum WAVError: Error, Equatable {
    case emptyBody
    case notReadable(String)
    case unsupportedSampleWidth(Int)

    public var description: String {
        switch self {
        case .emptyBody:
            return "empty audio body - the microphone produced no samples"
        case .notReadable(let e):
            return "not a readable WAV: \(e)"
        case .unsupportedSampleWidth(let w):
            return "expected 16-bit PCM samples, got \(w * 8)-bit"
        }
    }
}

public struct WAVInfo: Equatable {
    public let sampleWidth: Int
    public let channelCount: Int
    public let sampleRate: Int
    public let data: Data
    public init(sampleWidth: Int, channelCount: Int, sampleRate: Int, data: Data) {
        self.sampleWidth = sampleWidth
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.data = data
    }
}

public enum WAV {
    static let supportedSampleWidth = 2
    static let supportedChannelCount = 1
    static let supportedSampleRate = 16000

    public static func parse(_ d: Data) throws -> WAVInfo {
        guard !d.isEmpty else { throw WAVError.emptyBody }
        guard d.count >= 44 else { throw WAVError.notReadable("header too short") }
        guard ascii(d, 0) == "RIFF", ascii(d, 8) == "WAVE" else {
            throw WAVError.notReadable("missing RIFF/WAVE markers")
        }

        var sampleWidth = 0, channelCount = 0, sampleRate = 0
        var foundFormat = false
        var foundData: Data?
        var offset = 12
        while offset + 8 <= d.count {
            let chunkID = ascii(d, offset)
            let size = UInt64(leUInt32(d, offset + 4))
            let chunkStart = offset + 8
            guard Int64(chunkStart) + Int64(size) <= Int64(d.count), size <= Int(INT32_MAX) else {
                throw WAVError.notReadable("truncated or oversized chunk '\(chunkID)'")
            }
            if chunkID == "fmt " {
                guard size >= 16 else { throw WAVError.notReadable("fmt chunk too small") }
                let format = leUInt16(d, chunkStart)
                guard format == 1 else { throw WAVError.notReadable("not PCM (audio format \(format))") }
                channelCount = Int(leUInt16(d, chunkStart + 2))
                sampleRate = Int(leUInt32(d, chunkStart + 4))
                // bitsPerSample → bytes (16 → 2), matching Python's getsampwidth().
                sampleWidth = Int(leUInt16(d, chunkStart + 14)) / 8
                foundFormat = true
            } else if chunkID == "data" {
                foundData = d.subdata(in: chunkStart..<(chunkStart + Int(size)))
            }
            // Chunks are word-aligned (padded to even length).
            offset = chunkStart + Int(size) + (Int(size) % 2)
        }
        guard foundFormat else { throw WAVError.notReadable("missing fmt chunk") }
        guard let foundData else { throw WAVError.notReadable("missing data chunk") }
        return WAVInfo(sampleWidth: sampleWidth, channelCount: channelCount,
                       sampleRate: sampleRate, data: foundData)
    }

    /// RMS of raw signed-16-bit little-endian PCM samples. 0.0 for digital
    /// silence; roughly 3000-5000 for normal speech.
    public static func rmsPCM(_ pcm: Data) -> Double {
        let bytes = [UInt8](pcm)
        let usable = bytes.count - (bytes.count % 2)
        guard usable > 0 else { return 0 }
        var sum: Double = 0
        var count = 0
        var i = 0
        while i + 1 < usable {
            let low = UInt16(bytes[i])
            let high = UInt16(bytes[i + 1])
            let u: UInt16 = low | (high << 8)
            let s = Int16(bitPattern: u) // already little-endian on the wire
            let v = Int32(s)
            sum += Double(v) * Double(v)
            count += 1
            i += 2
        }
        guard count > 0 else { return 0 }
        return (sum / Double(count)).squareRoot()
    }

    /// Root-mean-square of a WAV's PCM samples. 0.0 for digital silence.
    public static func rms(_ d: Data) throws -> Double {
        let info = try parse(d)
        guard info.sampleWidth == supportedSampleWidth else {
            throw WAVError.unsupportedSampleWidth(info.sampleWidth)
        }
        return rmsPCM(info.data)
    }

    /// Build a 44-byte canonical WAV header for 16 kHz mono 16-bit PCM, with
    /// data- and RIFF-size placeholders the caller back-patches.
    public static func header16kMono16Bit(dataByteCount: Int) -> Data {
        var out = Data(capacity: 44)
        func appendASCII(_ s: String) { out.append(Data(s.utf8)) }
        func appendLE16(_ v: Int) { out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)) }
        func appendLE32(_ v: Int) {
            out.append(UInt8((v) & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
        }
        let blockAlign = 2 // mono s16
        let byteRate = 16000 * blockAlign
        appendASCII("RIFF"); appendLE32(36 + dataByteCount); appendASCII("WAVE")
        appendASCII("fmt "); appendLE32(16)
        appendLE16(1)              // PCM
        appendLE16(supportedChannelCount)
        appendLE32(supportedSampleRate)
        appendLE32(byteRate)
        appendLE16(blockAlign)
        appendLE16(16)             // bits per sample
        appendASCII("data"); appendLE32(dataByteCount)
        return out
    }

    static func ascii(_ d: Data, _ o: Int) -> String {
        guard o + 4 <= d.count else { return "" }
        return String(decoding: d.subdata(in: o..<(o + 4)), as: UTF8.self)
    }
    static func leUInt16(_ d: Data, _ o: Int) -> UInt16 {
        guard o + 2 <= d.count else { return 0 }
        return UInt16(d[o]) | (UInt16(d[o + 1]) << 8)
    }
    static func leUInt32(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        return UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }
}
