import AVFoundation
import Foundation
import TacetCore

/// In-process microphone capture to an in-memory WAV — absorbs the separate
/// `rec` binary (client/rec.swift) per the native-client design. The wire
/// format is 16 kHz, mono, 16-bit signed PCM, little endian, one `data` chunk.
///
/// The tap callback runs on an audio thread while `stop()` is called from the
/// main queue; the sample buffer is owned by a serial queue so the two never
/// race (the unsynchronised access rec.swift tolerated is more consequential
/// in-process). Permission is a TCC fact settled by `AgentController` before
/// capture — never inferred from frame counts.
public enum RecorderError: Error, CustomStringConvertible {
    case noInputStream(String)
    case couldNotStart(String)

    public var description: String {
        switch self {
        case .noInputStream(let m): return m
        case .couldNotStart(let m): return m
        }
    }
}

public struct Recording {
    public let wav: Data?     // nil when there is no usable audio
    public let frames: Int
    public let allSilent: Bool
    public let error: String? // capture-side cause

    public init(wav: Data?, frames: Int, allSilent: Bool, error: String?) {
        self.wav = wav
        self.frames = frames
        self.allSilent = allSilent
        self.error = error
    }
}

public final class Recorder {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "tacet.recorder")
    private var samples = [Int16]()
    private var peak: Int32 = 0
    private var started = false

    public init() {}

    /// Permission must already be granted. Throws on a device failure before
    /// the engine starts.
    public func start() throws {
        // Reset per-capture state. Recorder is long-lived and both of these
        // are instance properties, so without this every capture appends to
        // all previous audio: capture 2 transcribes 1+2, capture 3 transcribes
        // 1+2+3, and the WAV grows without bound. Presents as the transcript
        // repeating what you said last time.
        queue.sync {
            samples.removeAll(keepingCapacity: true)
            peak = 0
        }

        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw RecorderError.noInputStream(
                "default input device reports no usable input stream (\(inFormat.channelCount) ch, \(inFormat.sampleRate) Hz)")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16000, channels: 1, interleaved: true) else {
            throw RecorderError.couldNotStart("could not build the 16 kHz mono target format")
        }
        guard let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw RecorderError.couldNotStart("no converter from \(inFormat) to \(target)")
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter, target: target)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw RecorderError.couldNotStart("could not start the audio engine: \(error)")
        }
        started = true
    }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                         target: AVAudioFormat) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var provided = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if provided { status.pointee = .noDataNow; return nil }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0, let channel = out.int16ChannelData else { return }
        queue.sync {
            for i in 0..<Int(out.frameLength) {
                let s = channel[0][i]
                samples.append(s)
                peak = max(peak, abs(Int32(s)))
            }
        }
    }

    /// Stop capture, drain the tap, and finalise the in-memory WAV. Idempotent.
    public func stop() -> Recording {
        guard started else {
            return Recording(wav: nil, frames: 0, allSilent: false,
                             error: "capture was not started")
        }
        started = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let (frames, peakValue) = queue.sync { (samples.count, peak) }
        guard frames > 0 else {
            return Recording(wav: nil, frames: 0, allSilent: false,
                             error: "the input device delivered no audio at all")
        }
        guard peakValue > 0 else {
            // Every sample exactly zero is a muted device or a level at zero,
            // never a quiet room — a real ADC has a noise floor.
            return Recording(wav: nil, frames: frames, allSilent: true,
                             error: "captured \(frames) frames of digital silence - the input device is muted or its level is at zero")
        }
        let pcm = Data(bytes: samples, count: frames * 2)
        var wav = WAV.header16kMono16Bit(dataByteCount: frames * 2)
        wav.append(pcm)
        return Recording(wav: wav, frames: frames, allSilent: false, error: nil)
    }
}
