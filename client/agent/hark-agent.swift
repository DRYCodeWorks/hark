//  hark-agent — hold-to-talk dictation agent.
//
//  Hold Ctrl+Alt+Space, speak, release. `rec` (client/rec.swift, bundled at
//  Contents/MacOS/rec) records the mic to a WAV, the WAV is POSTed to the
//  hark server, the transcript comes back in the HTTP response, and it lands
//  on the clipboard and gets pasted (Cmd+V) into whatever app has focus.
//
//  This replaces client/init.lua and, with it, the Hammerspoon dependency.
//  See docs/superpowers/specs/2026-07-14-dictate-design.md for why the
//  transcript is pasted at the OS cursor rather than injected server-side:
//  the server cannot know which pane you are looking at, but macOS always
//  knows what has focus.
//
//  WHY A BUNDLE AND NOT A BARE BINARY
//
//  Both permissions this needs are keyed by TCC to a code identity. For an
//  .app that identity is the bundle ID plus its signature, and it survives
//  rebuilds. For a bare binary it is the path and the cdhash, so every
//  recompile invalidates the grant - and macOS leaves the old row visible in
//  the privacy pane with its toggle still ON while the grant no longer
//  applies. No prompt, no error, the hotkey simply stops firing. Bundle
//  stability is the single thing Hammerspoon was still buying us.
//
//  Microphone additionally requires NSMicrophoneUsageDescription in an
//  Info.plist, which a bare binary has nowhere to put.
//
//  WHY CARBON RegisterEventHotKey AND NOT AN NSEvent GLOBAL MONITOR
//
//  NSEvent.addGlobalMonitorForEvents cannot consume the event it observes, so
//  Ctrl+Alt+Space would reach the focused app as well as us. RegisterEventHotKey
//  consumes it, delivers pressed AND released as distinct events, and needs no
//  permission of its own. It is also what Hammerspoon's hs.hotkey used
//  underneath, so it is already proven against this exact key and hold pattern.
//
//  Accessibility is still required - not for the hotkey, but for synthesizing
//  the Cmd+V at the end. One prompt, not two.

import AVFoundation
import AppKit
import Carbon.HIToolbox
import Foundation

// ============================================================================
// Paths
// ============================================================================

let home = FileManager.default.homeDirectoryForCurrentUser

// Beside the server's own config.toml and key. The client half is JSON rather
// than TOML purely so this stays a single-file swiftc build: Swift has no
// stdlib TOML parser, and neither a SwiftPM manifest nor a hand-rolled parser
// earns its keep for three fields.
let configPath = home.appendingPathComponent(".config/hark/client.json")

// NOT /tmp/hark.wav. The Hammerspoon client uses that path, and the two are
// designed to coexist on the same Mac while a user migrates. Sharing it would
// let a recording from one client be read by the other.
let wavPath = URL(fileURLWithPath: "/tmp/hark-agent.wav")

let micProbePath = URL(fileURLWithPath: "/tmp/hark-agent-mic-probe.wav")

// ~/Library/Logs is where macOS expects an app's logs and where Console.app
// looks without being told. The Hammerspoon client wrote to ~/.hammerspoon/
// because that was the only directory it owned.
let logPath = home.appendingPathComponent("Library/Logs/hark-agent.log")

// Read by install-client.sh --doctor. The contract is unchanged from the
// Hammerspoon client's ~/.hammerspoon/.hark-mic-status, and it still exists
// for the same reason: TCC attributes a microphone request to the RESPONSIBLE
// process, so a probe run from a shell would test Terminal's grant, not this
// agent's, and would report a confidently wrong PASS. Only the agent can
// answer for the agent, so it writes the answer down where the shell can read
// it.
//
// Format, positional and read line-by-line by --doctor:
//   1: "ok" | "denied" | "error"
//   2: timestamp
//   3: optional single-line detail
let micStatusPath = home.appendingPathComponent(".config/hark/agent-mic-status")

// ============================================================================
// Logging
// ============================================================================

let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

// Mirrors the server's logging discipline: diagnostics only, never transcript
// content. rec's stderr names the device or the failure, not speech.
func log(_ message: String) {
    let line = "\(timestampFormatter.string(from: Date())) \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)

    let dir = logPath.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logPath) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: logPath)
    }
}

func beep() {
    // "Basso" is a built-in macOS alert sound, chosen because it reads as a
    // failure tone rather than routine feedback.
    NSSound(named: NSSound.Name("Basso"))?.play()
}

// ============================================================================
// On-screen overlay
// ============================================================================
//
// Replaces hs.alert. A non-activating floating panel: it must never steal
// focus, because the whole point of this tool is that the transcript lands in
// whatever the user was already typing into.

final class Overlay {
    static let shared = Overlay()

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    func show(_ text: String, duration: TimeInterval?) {
        hide()

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.preferredMaxLayoutWidth = 520

        // CGFloat.greatestFiniteMagnitude spelled out: NSSize has Int, Double
        // and CGFloat initializers, so the bare member is ambiguous.
        let size = label.sizeThatFits(NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude))
        let padding: CGFloat = 22
        let frame = NSRect(x: 0, y: 0, width: size.width + padding * 2, height: size.height + padding * 2)

        // .nonactivatingPanel is the load-bearing flag - without it, showing
        // the panel pulls keyboard focus away from the app the user is
        // dictating into.
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSVisualEffectView(frame: frame)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        label.frame = NSRect(x: padding, y: padding, width: size.width, height: size.height)
        container.addSubview(label)
        panel.contentView = container

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.minY + visible.height * 0.18
            ))
        }

        panel.orderFrontRegardless()
        self.panel = panel

        if let duration {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
                DispatchQueue.main.async { Overlay.shared.hide() }
            }
        }
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

func alert(_ text: String, _ duration: TimeInterval = 6) {
    Overlay.shared.show(text, duration: duration)
}

func failAlert(_ text: String, _ duration: TimeInterval = 7) {
    beep()
    alert(text, duration)
}

// ============================================================================
// Configuration
// ============================================================================

struct ClientConfig: Decodable {
    let server: String?
    let key: String?
}

// Loopback default: the single-machine setup, where the server runs on this
// same Mac. For two machines, set `server` to the transcribing machine's
// private address.
var serverURL = "http://127.0.0.1:8911/dictate"
var harkKey = ""

func loadConfig() {
    guard let data = try? Data(contentsOf: configPath) else {
        alert("hark: missing \(configPath.path) — run install-client.sh", 20)
        return
    }
    guard let config = try? JSONDecoder().decode(ClientConfig.self, from: data) else {
        alert("hark: \(configPath.path) is not valid JSON — run install-client.sh", 20)
        return
    }
    if let server = config.server, !server.isEmpty { serverURL = server }
    if let key = config.key { harkKey = key }

    if harkKey.isEmpty {
        alert("hark: no key configured in \(configPath.path)", 20)
    }
}

// ============================================================================
// Paste
// ============================================================================

func paste(_ text: String) {
    // Deliberately NOT saving and restoring the previous clipboard contents.
    // Leaving the transcript on the clipboard means a misfired paste - wrong
    // window focused, target app swallowing the keystroke - is recoverable
    // with a manual Cmd+V instead of having to re-speak the whole utterance.
    // Do not "fix" this by adding save/restore.
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)

    guard let source = CGEventSource(stateID: .combinedSessionState) else {
        failAlert("hark: could not create an event source to paste with.")
        return
    }

    // Setting .maskCommand explicitly rather than relying on ambient modifier
    // state: the response can arrive while Ctrl and Alt are still physically
    // held, and an inherited Ctrl+Alt+Cmd+V is not a paste in any app.
    let v = CGKeyCode(kVK_ANSI_V)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
    else {
        failAlert("hark: could not synthesize the paste keystroke.")
        return
    }
    down.flags = .maskCommand
    up.flags = .maskCommand

    // NEVER follow this with Return. The user reviews the transcript before
    // submitting it; auto-submit is a hard non-goal (see the design spec).
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

// ============================================================================
// HTTP
// ============================================================================
//
// Every failure branch both beeps AND names a likely cause. A silent failure
// is the worst outcome: if dictation does nothing, the instinct is to try
// again, and a second silent failure reads as "the mic is broken" when the
// real cause might be a stale key or a downed tailnet link.

// Best-effort extraction of the server's {"detail": "..."} error body, so its
// already-specific explanation reaches the alert instead of being dropped.
func extractDetail(_ data: Data?) -> String {
    guard let data, !data.isEmpty else { return "(no response body)" }
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let detail = object["detail"] as? String {
        return detail
    }
    return String(data: data, encoding: .utf8) ?? "(unreadable response body)"
}

func send(_ audio: Data) {
    guard let url = URL(string: serverURL) else {
        failAlert("hark: \(serverURL) is not a valid URL — check \(configPath.path)")
        return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(harkKey, forHTTPHeaderField: "X-Hark-Key")
    request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
    request.httpBody = audio
    request.timeoutInterval = 120

    log("sending \(audio.count) bytes to \(serverURL)")

    URLSession.shared.dataTask(with: request) { data, response, error in
        DispatchQueue.main.async {
            handleResponse(data: data, response: response, error: error)
        }
    }.resume()
}

func handleResponse(data: Data?, response: URLResponse?, error: Error?) {
    // Connection-level failure: unreachable host, DNS failure, timeout,
    // refused. Distinct from any HTTP status, and almost always the network
    // path rather than hark itself.
    if let error {
        failAlert(
            "hark: can't reach the server (\(serverURL)).\n"
                + "Check the tailnet is up (tailscale status) and hark is running.\n"
                + error.localizedDescription
        )
        return
    }

    guard let http = response as? HTTPURLResponse else {
        failAlert("hark: got a non-HTTP response from \(serverURL).")
        return
    }

    if http.statusCode == 200 {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String
        else {
            failAlert("hark: 200 OK but the response wasn't the expected JSON.")
            return
        }

        if text.isEmpty {
            // Not an error: silence, or audio that transcribed to no
            // alphanumeric content. Paste nothing.
            alert("heard nothing", 1.5)
            return
        }

        // Length only, never the transcript itself - mirroring the server's
        // own discipline. The log is local, but there is no reason to put
        // speech content in a log at all.
        log("pasting \(text.count) chars")
        paste(text)
        return
    }

    let detail = extractDetail(data)

    switch http.statusCode {
    case 401:
        failAlert(
            "hark: 401 unauthorized — \(detail)\n"
                + "Check that the key in \(configPath.path) matches the server's "
                + "~/.config/hark/key (re-run install-client.sh to refetch it)."
        )
    case 415:
        failAlert(
            "hark: 415 unsupported media type — \(detail)\n"
                + "This is a client bug (wrong Content-Type header), not a mic problem. "
                + "Please report it."
        )
    case 400:
        failAlert(
            "hark: 400 bad request — \(detail)\n"
                + "Almost certainly a microphone permission problem: check System "
                + "Settings -> Privacy & Security -> Microphone -> turn hark ON."
        )
    case 503:
        failAlert(
            "hark: 503 — whisper-server is down on the server. \(detail)\n"
                + "Check /tmp/hark-whisper.err on the server."
        )
    default:
        failAlert("hark: unexpected HTTP \(http.statusCode) — \(detail)")
    }
}

// ============================================================================
// Recording lifecycle
// ============================================================================

// rec ships inside the bundle rather than being installed alongside it, so
// the app is self-contained and a future codesign covers the recorder as a
// nested binary without a second signing step.
let recorderPath: URL? = Bundle.main.executableURL?
    .deletingLastPathComponent()
    .appendingPathComponent("rec")

var recorder: Process?

// rec's last one-line reason for exiting non-zero, so the alert the user
// actually sees names the cause instead of pointing at a log file.
var lastRecorderFailure: String?

func startRecording() {
    if recorder != nil { return } // already recording; guards a spurious double key-down

    if harkKey.isEmpty {
        failAlert("hark: no key configured — run install-client.sh or edit \(configPath.path)", 5)
        return
    }

    guard let recorderPath, FileManager.default.isExecutableFile(atPath: recorderPath.path) else {
        failAlert("hark: the bundled recorder is missing. Re-run install-client.sh.")
        return
    }

    try? FileManager.default.removeItem(at: wavPath) // never read a stale WAV

    Overlay.shared.show("● Recording…", duration: nil)

    let process = Process()
    process.executableURL = recorderPath
    process.arguments = [wavPath.path]

    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    process.terminationHandler = { finished in
        let stderrData = try? stderrPipe.fileHandleForReading.readToEnd()
        let stderrText = String(data: stderrData ?? Data(), encoding: .utf8) ?? ""

        DispatchQueue.main.async {
            recorder = nil
            lastRecorderFailure = nil

            // rec catches SIGTERM, finalizes the WAV and exits 0, so unlike
            // ffmpeg a non-zero exit here means something actually went wrong
            // and its stderr is one explanatory line rather than a banner.
            if finished.terminationStatus != 0 {
                log("rec exited \(finished.terminationStatus): \(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))")
                var reason = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                if reason.hasPrefix("rec: ") { reason = String(reason.dropFirst(5)) }
                if !reason.isEmpty { lastRecorderFailure = reason }
            }

            Overlay.shared.hide()

            // Sent with no settling delay. rec releases the AVAudioFile -
            // which is what finalizes the WAV header - and stops the engine
            // BEFORE exit, so by the time this runs the file is already
            // complete. The process exit IS the guarantee; a fixed sleep here
            // would be pure latency on every utterance.
            sendRecording()
        }
    }

    do {
        try process.run()
        recorder = process
    } catch {
        Overlay.shared.hide()
        failAlert("hark: the recorder failed to start (\(recorderPath.path)): \(error.localizedDescription)", 5)
    }
}

func stopRecording() {
    guard let process = recorder else { return } // key released with nothing recording
    // SIGTERM; rec finalizes the WAV header and exits 0. Deliberately does NOT
    // clear `recorder` or hide the indicator - the termination handler does
    // both, at the moment rec has actually exited.
    process.terminate()
}

func sendRecording() {
    guard let audio = try? Data(contentsOf: wavPath) else {
        // rec deletes the file rather than leave an unusable one, and exits
        // with a single explanatory line. Showing that line is what
        // distinguishes a denied microphone from a muted one from a dead
        // device; sending the user to a log to find out is how a permission
        // failure gets misread as a transcription failure.
        failAlert(
            "hark: nothing was recorded.\n"
                + (lastRecorderFailure ?? "See \(logPath.path) for the reason."),
            8
        )
        return
    }

    guard !audio.isEmpty else {
        // Not a permission problem: rec settles that with TCC before it opens
        // the device, and deletes the file rather than leave an empty one. A
        // zero-byte file means rec died before finalizing the WAV header.
        failAlert(
            "hark: recorded a zero-byte file - rec exited before finalizing the WAV.\n"
                + (lastRecorderFailure ?? "See \(logPath.path) for the reason."),
            8
        )
        return
    }

    send(audio)
}

// ============================================================================
// Hotkey
// ============================================================================

var hotKeyRef: EventHotKeyRef?

// A C function pointer, so it can capture nothing - startRecording and
// stopRecording are globals for exactly this reason. Carbon dispatches these
// on the main thread, which is also where every global they touch is mutated.
let hotKeyHandler: EventHandlerUPP = { _, event, _ -> OSStatus in
    guard let event else { return OSStatus(eventNotHandledErr) }
    switch Int(GetEventKind(event)) {
    case kEventHotKeyPressed:
        startRecording()
    case kEventHotKeyReleased:
        stopRecording()
    default:
        return OSStatus(eventNotHandledErr)
    }
    return noErr
}

func registerHotKey() -> Bool {
    var eventSpecs = [
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]

    let installed = InstallEventHandler(
        GetApplicationEventTarget(), hotKeyHandler, eventSpecs.count, &eventSpecs, nil, nil
    )
    guard installed == noErr else {
        log("InstallEventHandler failed: \(installed)")
        return false
    }

    // 'HARK' as an OSType, the conventional four-char signature.
    let hotKeyID = EventHotKeyID(signature: OSType(0x4841_524B), id: 1)

    // Ctrl+Alt+Space, NOT Option+Cmd+Space: the latter is macOS's built-in
    // Finder search shortcut and the system wins that fight.
    let registered = RegisterEventHotKey(
        UInt32(kVK_Space),
        UInt32(controlKey | optionKey),
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &hotKeyRef
    )
    guard registered == noErr else {
        log("RegisterEventHotKey failed: \(registered)")
        return false
    }
    return true
}

// ============================================================================
// Startup self-check: Accessibility
// ============================================================================
//
// The hotkey itself does not need Accessibility - RegisterEventHotKey works
// without it. The Cmd+V does: CGEvent.post is refused for an untrusted
// process, silently. So recording would work, transcription would work, and
// nothing would ever appear. Check it loudly at startup instead.
//
// Unlike the Hammerspoon client, which could only nag, this can actually
// trigger the system prompt - the app is the thing being granted, so it is
// allowed to ask.

func checkAccessibility() {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    guard !trusted else { return }

    alert(
        "hark: Accessibility is NOT granted.\n"
            + "Recording will work but the transcript can never be pasted.\n"
            + "System Settings -> Privacy & Security -> Accessibility -> turn ON hark.",
        20
    )
}

// ============================================================================
// Startup self-check: Microphone
// ============================================================================
//
// macOS's Microphone pane has no "+" button - it lists only apps that have
// ALREADY REQUESTED access. On a fresh install hark has never asked, so it
// does not appear, so there is nothing to toggle. The only way to make the
// consent dialog appear is to actually try to open the mic, which is what
// this probe does at startup rather than waiting for the first hotkey press.
//
// rec runs as this agent's CHILD, so TCC attributes the request to the agent
// (the responsible app) and the Info.plist usage string is the one shown.

func writeMicStatus(_ status: String, _ detail: String?) {
    try? FileManager.default.createDirectory(
        at: micStatusPath.deletingLastPathComponent(), withIntermediateDirectories: true
    )

    var body = "\(status)\n\(timestampFormatter.string(from: Date()))\n"
    if let detail {
        // One line, always third: --doctor reads it positionally and rec's
        // stderr can carry newlines.
        let collapsed = detail.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        body += "\(collapsed)\n"
    }
    try? body.write(to: micStatusPath, atomically: true, encoding: .utf8)
}

func probeMicrophone() {
    guard let recorderPath, FileManager.default.isExecutableFile(atPath: recorderPath.path) else {
        // Not a permission problem - the recorder simply is not there. Leave
        // the status file untouched rather than writing a misleading "denied".
        log("microphone probe skipped - no bundled recorder")
        return
    }

    try? FileManager.default.removeItem(at: micProbePath)

    let process = Process()
    process.executableURL = recorderPath
    process.arguments = [micProbePath.path, "0.4"]

    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    process.terminationHandler = { finished in
        let stderrData = try? stderrPipe.fileHandleForReading.readToEnd()
        let stderrText = (String(data: stderrData ?? Data(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.main.async {
            try? FileManager.default.removeItem(at: micProbePath)

            if finished.terminationStatus == 0 {
                writeMicStatus("ok", nil)
                return // silent on success - do not nag on every launch
            }

            // rec asks TCC before it opens the device and reserves exit 3 for
            // the answer. This used to be inferred from an empty capture,
            // which cannot work: an ungranted process still receives buffers,
            // full length and all zeros (hark issue #9).
            let denied = finished.terminationStatus == 3
            let reason = "rec exited \(finished.terminationStatus)."
                + (stderrText.isEmpty ? "" : " stderr: \(stderrText)")

            writeMicStatus(denied ? "denied" : "error", reason)
            log("microphone probe failed - \(reason)")

            if denied {
                alert(
                    "hark needs Microphone permission.\n"
                        + "A consent dialog should have appeared just now - click Allow.\n"
                        + "If you missed it: System Settings -> Privacy & Security -> "
                        + "Microphone -> turn ON hark.",
                    20
                )
            } else {
                alert(
                    "hark: the microphone probe failed, but not on permission.\n"
                        + reason + "\n"
                        + "Run ./install-client.sh --doctor for the full picture.",
                    20
                )
            }
        }
    }

    do {
        try process.run()
    } catch {
        writeMicStatus("error", "rec failed to start: \(error.localizedDescription)")
    }
}

// ============================================================================
// Main
// ============================================================================

let app = NSApplication.shared

// .accessory rather than .regular: no Dock icon, no menu bar, and - critically
// - activating the app never takes focus from whatever the user is dictating
// into. LSUIElement in Info.plist covers launch; this covers the running case.
app.setActivationPolicy(.accessory)

log("hark-agent \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") starting")

loadConfig()

if !registerHotKey() {
    failAlert(
        "hark: could not register the Ctrl+Alt+Space hotkey.\n"
            + "Another app is probably already using it.",
        20
    )
} else {
    alert("hark loaded", 1.5)
}

checkAccessibility()
probeMicrophone()

app.run()
