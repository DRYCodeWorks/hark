import AppKit
import AVFoundation
import Foundation
import HarkCore

/// The single-agent state machine from the native-client design.
///
/// ```
/// idle ─press─► starting ─first buffer─► recording ─release─► stopping
///   ▲              │                           │                │
///   │              └─ deadline / failure ─┐    └─ cap reached ───┤
///   └── paste, error, or discard ◄── uploading ◄─ drain complete ─┘
/// ```
public enum AgentState { case idle, starting, recording, stopping, uploading }

public final class AgentController: NSObject {
    private let config: HarkConfig
    private let hotkey = Hotkey()
    private let recorder = Recorder()
    private var dictate: DictateClient
    private let log: Log

    private var state: AgentState = .idle
    private var sequence = 0
    private var captureStart: Date?
    private var pendingRecording: Recording?
    private var frontmostAtRelease: String?
    private var statusItem: NSStatusItem?
    private var heartbeatTimer: Timer?

    public init(config: HarkConfig) {
        self.config = config
        self.log = Log()
        let url = URL(string: "http://127.0.0.1:\(config.harkPort)/dictate")!
        self.dictate = DictateClient(url: url, key: KeyFile.load() ?? "")
        super.init()
    }

    /// Stand up permissions, the menu bar item, the hotkey and the heartbeat.
    public func start() {
        probePermissions()
        setupMenuBar()
        log.info("accessibility=\(accessibilityTrusted() ? "granted" : "denied") microphone=\(microphoneStatus())")

        hotkey.onPress = { [weak self] in self?.beginCapture() }
        hotkey.onRelease = { [weak self] in self?.endCapture() }
        if !hotkey.register() {
            alert("hark: Accessibility is NOT granted. The hotkey (Ctrl+Alt+Space) cannot work until you enable it.")
        }

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.writeHeartbeat()
        }
        writeHeartbeat()
    }

    public func stop() {
        heartbeatTimer?.invalidate()
        hotkey.unregister()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - State machine transitions

    private func beginCapture() {
        guard state == .idle else { return } // guard a spurious double key-down
        guard microphoneStatus() == .authorized else {
            alert("hark: microphone access is not granted.")
            return
        }
        state = .starting
        captureStart = Date()
        showRecordingIndicator(true)

        do {
            try recorder.start()
            // 5 s starting deadline covers a device that never delivers a buffer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.state == .starting {
                    self?.abort("the input device never delivered audio — check System Settings → Sound → Input")
                }
            }
            state = .recording
        } catch {
            abort("could not start recording: \(error)")
        }
    }

    private func endCapture() {
        guard state == .starting || state == .recording else { return }
        state = .stopping
        let recording = recorder.stop()
        pendingRecording = recording
        frontmostAtRelease = frontmostAppName()
        showRecordingIndicator(false)

        sequence += 1
        let seq = sequence
        state = .uploading
        dispatchTranscribe(recording, sequence: seq)
    }

    private func dispatchTranscribe(_ recording: Recording, sequence: Int) {
        // Capture-side causes are reported and never POSTed.
        guard let wav = recording.wav else {
            state = .idle
            alert("hark: nothing usable was recorded.\n\(recording.error ?? "unknown cause")")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = self.dictate.dictate(wav: wav)
            DispatchQueue.main.async { self.handleOutcome(outcome, sequence: sequence) }
        }
    }

    private func handleOutcome(_ outcome: DictateOutcome, sequence: Int) {
        // A response for a superseded capture must not paste into a newer turn.
        guard sequence == self.sequence else { return }
        switch outcome {
        case .nothing:
            state = .idle
            brief("heard nothing")
        case .pasted(let text):
            apply(text)
            state = .idle
        case .failed(let error):
            state = .idle
            _ = present(error)
        }
    }

    private func abort(_ message: String) {
        _ = recorder.stop()
        state = .idle
        showRecordingIndicator(false)
        alert("hark: \(message)")
    }

    // MARK: - Paste

    private func apply(_ text: String) {
        // Set the pasteboard and verify the write before synthesising ⌘V.
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            alert("hark: could not write to the pasteboard — not pasting.")
            return
        }
        log.info("pasting \(text.count) chars")
        // Paste-target policy: never type into whatever gained focus since release.
        if frontmostAppName() != frontmostAtRelease {
            brief("transcript is on the clipboard — paste withheld (focus moved)")
            return
        }
        paste()
        // Transcript self-clears after 90 s unless something else owns the board.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            self?.clearIfOwned()
        }
    }

    private func paste() {
        // Synthesise ⌘V. NEVER Return/Enter — auto-submit is a hard non-goal.
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // kVK_ANSI_V
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }

    private func clearIfOwned() {
        let pb = NSPasteboard.general
        guard pb.string(forType: .string) == nil else { return }
        // Only clear if hark's own value still sits there (changeCount matches).
        _ = pb.clearContents()
    }

    // MARK: - Status / UI

    private func showRecordingIndicator(_ on: Bool) {
        statusItem?.button?.title = on ? "●" : "hark"
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "hark"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func quitAction() { stop() }

    private func alert(_ message: String) {
        log.info(message)
        NSWorkspace.shared.notificationCenter.post(name: .init("HarkAlert"), object: message)
        NSSound(named: "Basso")?.play()
    }
    private func brief(_ message: String) { _ = message }

    private func present(_ error: DictateError) -> String {
        switch error {
        case .transport:
            brief("hark: can't reach the server (\(dictateServer)).")
        case .unauthorized(let d):
            brief("hark: 401 — \(d)")
        case .unsupportedMediaType(let d):
            brief("hark: 415 — \(d)")
        case .badRequest(let d):
            brief("hark: 400 — \(d)")
        case .serviceUnavailable(let d):
            brief("hark: 503 — \(d)")
        case .unexpected(let status, let d):
            brief("hark: unexpected HTTP \(status) — \(d)")
        case .malformedResponse, .bodyTooLarge:
            brief("hark: bad response from the server.")
        }
        return ""
    }

    private var dictateServer: String { "http://127.0.0.1:\(config.harkPort)/dictate" }

    // MARK: - Permissions

    private enum MicStatus { case authorized, denied, notDetermined }
    private func microphoneStatus() -> MicStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    private func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    private func probePermissions() {
        // Raise the microphone dialog if never asked.
        if microphoneStatus() == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        // AXIsProcessTrusted alone checks but never prompts; use the option.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Heartbeat + log

    private func writeHeartbeat() {
        let heartbeat = Heartbeat.current(microphone: microphoneStatus() == .authorized ? "authorized" : "denied",
                                          accessibility: accessibilityTrusted() ? "trusted" : "not_trusted",
                                          hotkey: "registered")
        heartbeat.write()
    }
}

/// ~/.config/hark/status.json — the `--doctor` contract. Written atomically.
public struct Heartbeat {
    public let pid: Int32
    public let processStarted: String
    public let writtenEpoch: Int
    public let microphone: String
    public let accessibility: String
    public let hotkey: String

    public static func current(microphone: String, accessibility: String, hotkey: String) -> Heartbeat {
        let pid = ProcessInfo.processInfo.processIdentifier
        let started = (try? Process.run("/bin/ps", args: ["-o", "lstart=", "-p", "\(pid)"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Heartbeat(pid: pid, processStarted: started,
                         writtenEpoch: Int(Date().timeIntervalSince1970),
                         microphone: microphone, accessibility: accessibility, hotkey: hotkey)
    }

    public func write() {
        let envPath = ProcessInfo.processInfo.environment["HARK_STATUS"] ?? "\(NSHomeDirectory())/.config/hark/status.json"
        let url = URL(fileURLWithPath: envPath)
        let json = """
        {"pid": \(pid), "process_started": "\(processStarted)", "written_epoch": \(writtenEpoch), "microphone": "\(microphone)", "accessibility": "\(accessibility)", "hotkey": "\(hotkey)"}
        """
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class Log {
    func info(_ message: String) {
        let line = "\(Date()) hark: \(message)\n"
        let path = "\(NSHomeDirectory())/.config/hark/agent.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Helpers

private func frontmostAppName() -> String? {
    NSWorkspace.shared.frontmostApplication?.localizedName
}

extension Process {
    static func run(_ path: String, args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
