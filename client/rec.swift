//  rec — record the system default audio input to a 16 kHz mono s16 WAV.
//
//  usage: rec <output.wav> [max-seconds]
//
//  Runs until SIGTERM (the dictate client sends it on key-up), or until
//  max-seconds if given. Exits 0 having written a finalized WAV, or non-zero
//  with a one-line reason on stderr. No file is left behind on failure.
//
//    0  a finalized WAV containing audio
//    1  something else went wrong (the reason is on stderr)
//    2  bad usage
//    3  TCC has not granted microphone access - client/init.lua keys on this
//       exact code to tell a permission problem from every other failure
//    4  the default input device has no usable input stream (0 ch or 0 Hz)
//    5  the device delivered no audio at all
//    6  the device delivered only digital silence (muted, or level at zero)
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

// PERMISSION IS A TCC FACT, NOT SOMETHING TO INFER FROM THE AUDIO.
//
// A process with no microphone grant is not refused the device. It opens
// normally, reports the device's real format, and receives the full
// complement of buffers - with every sample exactly zero. Measured on a
// Scarlett 2i2 from a process whose status was notDetermined: 153,600 frames
// in 3 s, peak amplitude 0.0. macOS substitutes silence rather than failing,
// so that an app cannot infer microphone activity it has no right to observe.
//
// So a frame count can never see a denial - and neither can the sample-rate
// guard below, because format negotiation succeeds under denial too. The only
// way to learn the answer is to ask TCC for it.
let permissionHelp = "System Settings -> Privacy & Security -> Microphone "
    + "-> turn Hammerspoon ON"

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    break
case .notDetermined:
    // Nobody has asked yet, and Hammerspoon is not listed under Microphone
    // until something does - so failing outright here would leave the user no
    // toggle to flip. Ask, and wait for the answer; continuing without one
    // would record the substituted silence.
    //
    // The wait pumps the main run loop instead of blocking on a semaphore:
    // requestAccess delivers its completion on an unspecified queue, and a
    // blocked main thread would deadlock if that queue turns out to be main.
    var granted: Bool?
    AVCaptureDevice.requestAccess(for: .audio) { granted = $0 }
    while granted == nil {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    if granted != true { die("microphone access denied - \(permissionHelp)", 3) }
case .denied, .restricted:
    die("microphone access denied - \(permissionHelp)", 3)
@unknown default:
    die("microphone access is in an unrecognized state - \(permissionHelp)", 3)
}

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
// Loudest sample seen, tracked as Int32 because abs(Int16.min) overflows.
// Only the zero/non-zero distinction is used - see stop().
var peakSample: Int32 = 0
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
        if let samples = outBuffer.int16ChannelData {
            for i in 0..<Int(outBuffer.frameLength) {
                peakSample = max(peakSample, abs(Int32(samples[0][i])))
            }
        }
    } catch {
        FileHandle.standardError.write("rec: write failed: \(error)\n".data(using: .utf8)!)
    }
}

func stop() -> Never {
    input.removeTap(onBus: 0)
    engine.stop()
    file = nil // releases the AVAudioFile, which finalizes the WAV header

    // Permission was settled before the device was ever opened, so these are
    // the two remaining ways to come back with nothing usable, and neither is
    // a permission problem. Both leave no file: an empty or silent WAV would
    // otherwise be POSTed and come back as "heard nothing", which reads like a
    // transcription problem rather than a capture one. Say which it was.
    if framesWritten == 0 {
        try? FileManager.default.removeItem(at: outURL)
        die("the input device delivered no audio at all - check System Settings "
            + "-> Sound -> Input", 5)
    }
    // Every sample exactly zero is not a quiet room - a real ADC has a noise
    // floor. It is a muted device, an input level at zero, or a virtual device
    // with nothing routed into it. Deliberately an equality test and not a
    // loudness threshold: quiet speech must still go through.
    if peakSample == 0 {
        try? FileManager.default.removeItem(at: outURL)
        die("captured \(framesWritten) frames of digital silence - the input "
            + "device is muted or its level is at zero", 6)
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

// Ceiling for the case where the first buffer never arrives at all - a device
// that stopped delivering. Without it the countdown above, which is armed by
// that first buffer, would never be scheduled and the process would sit
// forever. stop() then finds zero frames and exits 5.
if let maxSeconds {
    DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds + 3.0) { stop() }
}

RunLoop.main.run()
