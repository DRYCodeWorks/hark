//  rec — record the system default audio input to a 16 kHz mono s16 WAV.
//
//  usage: rec <output.wav> [max-seconds]
//
//  Runs until SIGTERM (the dictate client sends it on key-up), or until
//  max-seconds if given. Exits 0 having written a finalized WAV, or non-zero
//  with a one-line reason on stderr.
//
//  WHY THIS EXISTS INSTEAD OF ffmpeg
//
//  ffmpeg's avfoundation input device reads the sample format from the first
//  buffer the device delivers and accepts only PACKED layouts: f32, or signed
//  16/24/32-bit. A Focusrite Scarlett 2i2 offers exactly one physical layout,
//  at every one of its six sample rates: 24-bit signed integer UNPACKED in 4
//  bytes, high-aligned. ffmpeg cannot consume that, and says so with the
//  distinctly unhelpful "audio format is not supported".
//
//  ffmpeg nonetheless worked about half the time, because CoreAudio sometimes
//  hands a capture client the device's VIRTUAL format (Float32, converted by
//  the HAL) rather than its physical one - and which one you get varies per
//  open. That is the whole of the intermittency. No ffmpeg option influences
//  it: the avfoundation demuxer exposes no audio format knob, and there is no
//  packed format on the hardware to pin the device to.
//
//  AVAudioEngine's inputNode is Float32 by contract and never exposes the
//  physical format, so this failure mode cannot occur here.

import AVFoundation
import Foundation

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write("rec: \(msg)\n".data(using: .utf8)!)
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: rec <output.wav> [max-seconds]", 2) }
let outURL = URL(fileURLWithPath: args[1])
let maxSeconds = args.count >= 3 ? Double(args[2]) : nil

let engine = AVAudioEngine()
let input = engine.inputNode
let inFormat = input.inputFormat(forBus: 0)

// A device that is present but has no usable input stream reports 0 Hz. Bail
// with a specific message rather than installing a tap that never fires.
guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
    die("default input device reports no usable input stream "
        + "(\(inFormat.channelCount) ch, \(inFormat.sampleRate) Hz) - "
        + "check System Settings -> Sound -> Input", 4)
}

guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                 sampleRate: 16000, channels: 1, interleaved: true)
else { die("could not build the 16 kHz mono target format") }

guard let converter = AVAudioConverter(from: inFormat, to: target) else {
    die("no converter from \(inFormat) to \(target)")
}

// Held as an optional so stop() can release it: AVAudioFile writes the final
// WAV header when it is deallocated, so exiting without clearing this leaves
// a file whose header understates its length.
var file: AVAudioFile?
do {
    file = try AVAudioFile(forWriting: outURL, settings: target.settings,
                           commonFormat: .pcmFormatInt16, interleaved: true)
} catch {
    die("could not open \(outURL.path) for writing: \(error)")
}

var framesWritten: AVAudioFramePosition = 0
let launchedAt = DispatchTime.now()
var firstBufferLoggedAt: Double?

input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
    if firstBufferLoggedAt == nil {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - launchedAt.uptimeNanoseconds) / 1e6
        firstBufferLoggedAt = ms
        if ProcessInfo.processInfo.environment["REC_TIMING"] != nil {
            FileHandle.standardError.write("rec: first buffer at \(Int(ms)) ms\n".data(using: .utf8)!)
        }
        // The countdown starts HERE, not at engine.start(): start() returns
        // before a USB interface is actually delivering samples (~670 ms
        // early on a Scarlett 2i2), so a window opened there would spend most
        // of a short request waiting for the device. "max-seconds" should
        // mean seconds of audio.
        if let maxSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds) { stop() }
        }
    }
    // Capacity must cover the resample ratio (48k -> 16k shrinks, but a
    // device running at 44.1k or a partial buffer can round up), plus slack.
    let ratio = target.sampleRate / inFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

    var supplied = false
    var error: NSError?
    converter.convert(to: outBuffer, error: &error) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
    if let error {
        FileHandle.standardError.write("rec: convert failed: \(error)\n".data(using: .utf8)!)
        return
    }
    guard outBuffer.frameLength > 0 else { return }
    do {
        try file?.write(from: outBuffer)
        framesWritten += AVAudioFramePosition(outBuffer.frameLength)
    } catch {
        FileHandle.standardError.write("rec: write failed: \(error)\n".data(using: .utf8)!)
    }
}

func stop() -> Never {
    input.removeTap(onBus: 0)
    engine.stop()
    file = nil // releases the AVAudioFile, which finalizes the WAV header

    // Distinguish "the mic is muted or denied" from "we recorded silence":
    // an empty file would otherwise be POSTed and come back as "heard
    // nothing", which reads like a transcription problem rather than a
    // capture one. Leave no file at all, and say why.
    if framesWritten == 0 {
        try? FileManager.default.removeItem(at: outURL)
        die("captured no audio - check System Settings -> Privacy & Security "
            + "-> Microphone -> Hammerspoon is ON", 3)
    }
    exit(0)
}

// SIG_IGN first, then a dispatch source: a raw signal handler may not call
// arbitrary code, and exiting from one would skip the header finalization
// above. A dispatch source runs stop() as ordinary code on the main queue.
//
// The sources are kept in this array because they must stay alive for the
// whole run - a signal source that deallocates hands the signal back to its
// default disposition, and the process then dies on SIGTERM (exit 143)
// without ever finalizing the WAV. Retaining a `source as AnyObject` bridge
// does NOT keep the source itself alive; it retains a temporary.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { stop() }
    source.resume()
    signalSources.append(source)
}

// prepare() allocates the render resources up front, so start() only has to
// bring the device up.
engine.prepare()
do {
    try engine.start()
} catch {
    die("could not start the audio engine: \(error)")
}

// Ceiling for the case where the first buffer never arrives at all - a denied
// or muted microphone. Without it the countdown above, which is armed by that
// first buffer, would never be scheduled and the process would sit forever.
// stop() then finds zero frames and exits 3 with the permission message.
if let maxSeconds {
    DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds + 3.0) { stop() }
}

RunLoop.main.run()
