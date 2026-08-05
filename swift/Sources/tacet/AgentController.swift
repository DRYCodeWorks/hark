import AppKit
import AVFoundation
import Foundation
import TacetCore

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
    private let config: TacetConfig
    private let clientConfig: ClientConfig
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

    public init(config: TacetConfig) {
        self.config = config
        self.log = Log()

        // Client addressing is NOT the server's deployment config. A recording
        // Mac has no server, no key file and nothing on loopback; and a server
        // bound to a tailnet address is unreachable at 127.0.0.1 even on the
        // machine running it. See ClientConfig.
        let client: ClientConfig
        do {
            client = try ClientConfig.load(defaultPort: config.tacetPort)
        } catch {
            // Fatal on purpose. Continuing would build a client pointed at
            // loopback that fails on every utterance with a connection error,
            // which reads as "the server is down" rather than "your config is
            // wrong" — and that misdirection is expensive.
            FileHandle.standardError.write("tacet: \(error)\n".data(using: .utf8)!)
            exit(2)
        }
        self.clientConfig = client
        self.dictate = DictateClient(url: client.serverURL, key: client.key)
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
            alert("tacet: could not bind Ctrl+Alt+Space — something else is probably holding it.")
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
            alert("tacet: microphone access is not granted.")
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
            alert("tacet: nothing usable was recorded.\n\(recording.error ?? "unknown cause")")
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
        alert("tacet: \(message)")
    }

    // MARK: - Paste

    private func apply(_ transcript: String) {
        // A trailing space, so consecutive dictations do not run together.
        //
        // The server sanitiser ends with .strip(), and Whisper's own leading
        // space goes with it — correct for an API, which should return the
        // transcript and not presentation whitespace. But two dictations into
        // the same field then paste as "one, two, three.one, two, three." with
        // nothing between them. Long-standing; the Lua client did the same.
        //
        // Trailing rather than leading: a leading space would open an empty
        // field with whitespace, and there is no reliable way to read what sits
        // immediately before the cursor to decide. Trailing is occasionally
        // redundant and never wrong.
        let text = transcript + " "

        // Set the pasteboard and verify the write before synthesising ⌘V.
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            alert("tacet: could not write to the pasteboard — not pasting.")
            return
        }
        log.info("pasting \(transcript.count) chars")
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
        // Re-checked here, not just at startup: the grant can be revoked, or
        // silently invalidated by a rebuild, while the process keeps running,
        // and this is the moment it matters. Without it every step above still
        // reports success — the pasteboard write, the log line — and an
        // untrusted process is indistinguishable from a dropped event.
        guard accessibilityTrusted() else {
            alert("tacet: Accessibility is not granted, so the transcript cannot be pasted. "
                + "It IS on the clipboard — press ⌘V. "
                + "System Settings -> Privacy & Security -> Accessibility -> turn ON tacet.")
            return
        }

        // Synthesise ⌘V. NEVER Return/Enter — auto-submit is a hard non-goal.
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // kVK_ANSI_V
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)

        // HOLD THE KEY. Posting key-up immediately after key-down is a
        // zero-duration keystroke, which some apps silently drop — the events
        // arrive, nothing acts on them, and the transcript never appears.
        // hs.eventtap.keyStroke, the implementation being replaced, holds for
        // 200 ms (`local keyDelay = 200000`, then usleep between down and up);
        // the tap and the flags are otherwise identical. Async rather than a
        // sleep so the run loop is not stalled behind it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            up?.flags = .maskCommand
            up?.post(tap: .cghidEventTap)
        }
    }

    private func clearIfOwned() {
        let pb = NSPasteboard.general
        guard pb.string(forType: .string) == nil else { return }
        // Only clear if tacet's own value still sits there (changeCount matches).
        _ = pb.clearContents()
    }

    // MARK: - Status / UI

    private func showRecordingIndicator(_ on: Bool) {
        statusItem?.button?.title = on ? "●" : "tacet"
        // The menu bar title alone is easy to miss on a crowded bar, and it is
        // the only signal that the mic is actually open. nil duration: cleared
        // when capture really ends, never on a timer.
        if on {
            Overlay.shared.show("● Recording…", duration: nil)
        } else {
            Overlay.shared.hide()
        }
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "tacet"
        let menu = NSMenu()
        // target MUST be set. A menu item with a nil target sends its action up
        // the responder chain, and AgentController is not in it — it is not the
        // app delegate and owns no window. So nothing responds to quitAction,
        // AppKit greys the item out during validation, and Quit does nothing at
        // all. The failure is silent: the menu builds, the item appears.
        let quit = NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func quitAction() { stop() }

    private func alert(_ message: String) {
        log.info(message)
        // Was posted to an NSWorkspace notification nobody observed, which
        // discarded the whole diagnostic surface. Show it, and beep: if
        // dictation does nothing the instinct is to try again, and a second
        // silent failure reads as a broken mic rather than a stale key.
        Overlay.beep()
        Overlay.shared.show(message, duration: 7)
        NSSound(named: "Basso")?.play()
    }
    /// Short, non-error feedback — "heard nothing", "paste withheld". Was a
    /// no-op, so the two states a user is most likely to hit and misread as a
    /// hang produced no feedback at all. No beep: neither is a failure.
    private func brief(_ message: String) {
        log.info(message)
        Overlay.shared.show(message, duration: 2)
    }

    private func present(_ error: DictateError) -> String {
        switch error {
        case .transport:
            brief("tacet: can't reach the server (\(dictateServer)).")
        case .unauthorized(let d):
            brief("tacet: 401 — \(d)")
        case .unsupportedMediaType(let d):
            brief("tacet: 415 — \(d)")
        case .badRequest(let d):
            brief("tacet: 400 — \(d)")
        case .serviceUnavailable(let d):
            brief("tacet: 503 — \(d)")
        case .unexpected(let status, let d):
            brief("tacet: unexpected HTTP \(status) — \(d)")
        case .malformedResponse, .bodyTooLarge:
            brief("tacet: bad response from the server.")
        }
        return ""
    }

    private var dictateServer: String { clientConfig.serverURL.absoluteString }

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
            // Wait for the answer rather than discarding it. The completion is
            // delivered on an unspecified queue, so this pumps the run loop
            // instead of blocking on a semaphore, which would deadlock if that
            // queue turned out to be main. Continuing without the answer means
            // recording the substituted silence macOS hands an ungranted
            // process — full-length buffers of zeros, indistinguishable from a
            // quiet room until you check the peak.
            var granted: Bool?
            AVCaptureDevice.requestAccess(for: .audio) { granted = $0 }
            let deadline = Date(timeIntervalSinceNow: 60)
            while granted == nil, Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            if granted != true {
                log.info("microphone access was not granted")
            }
        }
        // AXIsProcessTrusted alone checks but never prompts; use the option.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Heartbeat + log

    private func writeHeartbeat() {
        let heartbeat = Heartbeat.current(microphone: microphoneStatus() == .authorized ? "authorized" : "denied",
                                          accessibility: accessibilityTrusted() ? "trusted" : "not_trusted",
                                          hotkey: hotkey.isRegistered ? "registered" : "not_registered")
        heartbeat.write()
    }
}

/// ~/.config/tacet/status.json — the `--doctor` contract. Written atomically.
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
        let envPath = ProcessInfo.processInfo.environment["TACET_STATUS"] ?? "\(NSHomeDirectory())/.config/tacet/status.json"
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
        let line = "\(Date()) tacet: \(message)\n"
        let path = "\(NSHomeDirectory())/.config/tacet/agent.log"
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
