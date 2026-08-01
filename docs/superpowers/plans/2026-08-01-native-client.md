# Native Swift Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Hammerspoon Lua client with a signed, notarised menu-bar Swift agent that captures in-process, verifies its own transport, and sanitises what it pastes.

**Architecture:** One SPM package built and signed in CI, shipped as a notarised `Hark.app` release artifact. `install-client.sh` downloads and verifies it instead of compiling. Capture moves in-process (no `rec` child, no `/tmp/hark.wav`). The client independently sanitises and bounds every server response.

**Tech Stack:** Swift 5.9+ / SPM, AVFoundation, Carbon or CGEventTap (decided by Task 1), Foundation `URLSession`, bash, Python 3.13 / FastAPI (server side).

**Spec:** `docs/superpowers/specs/2026-07-31-native-client-design.md` (revision 6). Read it before Task 1. Where this plan and the spec disagree, the spec wins — report the conflict rather than guessing.

## Global Constraints

Every task's requirements implicitly include these. Values are copied verbatim from the spec.

- **macOS floor:** 13 (set by `SMAppService.mainApp`).
- **Bundle ID:** `com.drycodeworks.hark-agent` — a new identifier, not an existing launchd label.
- **Install location:** `~/Applications/Hark.app`. No `sudo` anywhere in the install path.
- **Signing:** Developer ID + hardened runtime + `com.apple.security.device.audio-input` entitlement. Notarised and stapled in CI.
- **Wire format:** 16 kHz, mono, 16-bit signed PCM, little-endian, single `data` chunk.
- **Response bounds:** 1 MiB body (enforced *before* JSON decode), 8 KiB sanitised transcript, 2 KiB sanitised error `detail`. **Reject, never truncate.**
- **Timings:** 5 s starting deadline, 120 s capture cap, 30 s request timeout, 30 s status heartbeat, 90 s `--doctor` staleness limit, 90 s clipboard self-clear.
- **Transport:** HTTPS for every non-loopback hostname. Plain HTTP only for numeric loopback, or for a numeric IP literal listed in `insecure_transport_hosts`.
- **Never** synthesise Return after ⌘V. **Never** restore the previous clipboard.
- **Log lengths, never transcript content.** This applies to the agent, the server, and every test fixture.
- The client must not require the Xcode command line tools. `xcrun` and `stapler` are CI-only.

## Task Dependency Graph

```
Task 1 (spike) ──gates──► Tasks 8, 9          [hotkey mechanism]
Tasks 2-3 (server)  ── independent, start immediately, separately shippable
Task 4 (package skeleton) ──► Tasks 5, 6, 7 ──► Tasks 8, 9 ──► Task 10
Task 11 (CI/release) ──► Tasks 12-14 (installer) ──► Task 15 (docs)
```

Tasks 2 and 3 touch only `src/hark/` and `tests/`. Tasks 5, 6 and 7 touch disjoint Swift files and can run in parallel once Task 4 lands.

---

### Task 1: Phase 0 hotkey spike

**This task produces a decision, not shipped code.** Nothing downstream may start until its verdict is recorded in the spec.

**Files:**
- Create: `spike/hotkey/carbon.swift`, `spike/hotkey/eventtap.swift`, `spike/hotkey/README.md`
- Modify: `docs/superpowers/specs/2026-07-31-native-client-design.md` (record the verdict)

**Interfaces:**
- Consumes: nothing.
- Produces: a recorded decision — `carbon` or `eventtap` — that Tasks 8 and 9 read from the spec.

The spike answers two questions. Do not answer them by reasoning; measure.

1. Does a keyboard `CGEventTap` require Input Monitoring (`kTCCServiceListenEvent`) *in addition to* Accessibility? `README.md:266-268` asserts from this project's own experience that an `hs.eventtap` watching `flagsChanged` does. If a keyDown/keyUp tap also does, Carbon needs one grant and the tap needs two.
2. Is `kEventHotKeyReleased` reliable enough for hold-to-talk?

- [ ] **Step 1: Build both spikes as signed bundles**

Both must be tested as a **signed, notarised bundle**, not a bare binary — TCC binds to the designated requirement, and a bare binary's behaviour does not generalise.

- [ ] **Step 2: Run the measurement protocol**

For each mechanism, on macOS 13 and on the newest available:

| Check | Pass condition |
|---|---|
| 200 press/release cycles | **Zero** missed releases. A missed release strands the agent in `recording`, so the bar is zero, not low |
| Modifier roll | Press ⌃⌥Space, add ⇧ mid-hold, release. Release still delivered |
| Sustained CPU load | Zero missed releases under load |
| Display sleep/wake mid-hold | State recoverable, no stranded capture |
| Grant state | Record which TCC panes the app appears in after first run: Accessibility only, or Accessibility + Input Monitoring |
| Collision | Register while a second app holds the chord, with and without `kEventHotKeyExclusive`. Record whether registration reports it |

- [ ] **Step 3: Record the verdict in the spec**

Replace the spec's "Hotkey | **Undecided.**" decision row and the Phase 0 section with the outcome and the measurements behind it. If Carbon wins, state that `kEventHotKeyExclusive` is mandatory.

- [ ] **Step 4: Commit**

```bash
git add spike/hotkey docs/superpowers/specs/2026-07-31-native-client-design.md
git commit -m "[hark] Decide the hotkey mechanism from measurement"
```

---

### Task 2: Branch the server's 400 detail by cause

Independent of all Swift work. Ship it whenever.

**Files:**
- Modify: `src/hark/audio.py`, `src/hark/app.py:100-108`
- Test: `tests/test_app.py:98-115`, `tests/test_audio.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `InvalidAudioError.kind: str`, one of `"empty"`, `"unreadable"`, `"format"`. `DictateClient` (Task 7) relies on 400 meaning *client audio format bug*, not microphone permission.

`app.py:103-107` currently returns one detail for every `InvalidAudioError` — "Check that the client has microphone permission and is sending 16 kHz mono 16-bit PCM WAV" — and `tests/test_app.py:107` asserts that wording. Right for an empty body; wrong for a malformed header, which the native client can produce because it hand-builds one.

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_app.py
def test_empty_body_still_names_the_microphone(stub_transcribe):
    """A zero-byte WAV is still most likely a mis-permissioned mic."""
    response = TestClient(app).post("/dictate", content=b"", headers=HEADERS)
    assert response.status_code == 400
    assert "microphone" in response.json()["detail"].lower()


def test_malformed_wav_does_not_blame_the_microphone(stub_transcribe):
    """The native client hand-builds its header. A header bug must not send
    the user to Privacy & Security -> Microphone."""
    response = TestClient(app).post(
        "/dictate", content=b"not a wav at all", headers=HEADERS
    )
    assert response.status_code == 400
    detail = response.json()["detail"].lower()
    assert "microphone" not in detail and "mic " not in detail
    assert "wav" in detail or "format" in detail
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/test_app.py -k "microphone or malformed" -v`
Expected: `test_malformed_wav_does_not_blame_the_microphone` FAILS — the current detail contains "microphone" for every cause.

- [ ] **Step 3: Give `InvalidAudioError` a kind**

```python
# src/hark/audio.py
class InvalidAudioError(Exception):
    """The request body is not a WAV we can measure.

    `kind` lets the HTTP layer choose advice that matches the cause. Every
    cause used to produce the same "check your microphone" detail, which is
    right for an empty body and actively misleading for a malformed header.
    """

    def __init__(self, message: str, kind: str) -> None:
        super().__init__(message)
        self.kind = kind
```

Then tag each raise site — `"empty"` at `audio.py:38`, `"format"` at `:46`, `"unreadable"` at `:53`:

```python
        raise InvalidAudioError(
            "empty audio body - the microphone produced no samples", "empty"
        )
...
                raise InvalidAudioError(
                    f"expected 16-bit PCM samples, got {width * 8}-bit", "format"
                )
...
        raise InvalidAudioError(f"not a readable WAV: {exc}", "unreadable") from exc
```

- [ ] **Step 4: Branch the advice in `app.py`**

```python
    except InvalidAudioError as exc:
        logger.warning("rejected audio: %s", exc)
        if exc.kind == "empty":
            advice = (
                "Check that the client has microphone permission and is "
                "sending 16 kHz mono 16-bit PCM WAV."
            )
        else:
            advice = (
                "The client sent audio this server cannot read. Expected "
                "16 kHz mono 16-bit PCM WAV. This is a client bug, not a "
                "microphone permission problem."
            )
        raise HTTPException(status_code=400, detail=f"{exc}. {advice}") from exc
```

- [ ] **Step 5: Run the full suite**

Run: `uv run --locked pytest -q`
Expected: PASS. If `test_dictate_rejects_an_empty_body_naming_the_real_cause` still exists and duplicates the new empty-body test, delete the older one rather than keeping both.

- [ ] **Step 6: Commit**

```bash
git add src/hark/audio.py src/hark/app.py tests/test_app.py
git commit -m "[hark] Stop blaming the microphone for malformed audio"
```

---

### Task 3: Enforce the full wire format server-side

**Files:**
- Modify: `src/hark/audio.py:42-50`
- Test: `tests/test_audio.py`

**Interfaces:**
- Consumes: `InvalidAudioError(message, kind)` from Task 2.
- Produces: server rejection of any WAV that is not 16 kHz mono 16-bit.

`audio.py:22` documents the wire format in a comment while `:45` enforces only sample width. A stereo or 44.1 kHz WAV is accepted today, and the RMS is then silently mis-scaled against a threshold calibrated for mono 16 kHz.

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_audio.py
import io, wave, pytest
from hark.audio import rms, InvalidAudioError


def _wav(channels: int, rate: int, width: int = 2, frames: int = 1600) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(width)
        w.setframerate(rate)
        w.writeframes(b"\x00\x00" * frames * channels)
    return buf.getvalue()


def test_rejects_stereo():
    with pytest.raises(InvalidAudioError, match="mono"):
        rms(_wav(channels=2, rate=16000))


def test_rejects_wrong_sample_rate():
    with pytest.raises(InvalidAudioError, match="16000|16 kHz"):
        rms(_wav(channels=1, rate=44100))


def test_accepts_the_documented_format():
    assert rms(_wav(channels=1, rate=16000)) == 0.0
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/test_audio.py -k "stereo or sample_rate" -v`
Expected: both FAIL — stereo and 44.1 kHz currently pass through.

- [ ] **Step 3: Enforce channels and rate**

```python
# src/hark/audio.py, inside the `with wave.open(...)` block, after the width check
            channels = reader.getnchannels()
            if channels != SUPPORTED_CHANNELS:
                raise InvalidAudioError(
                    f"expected mono audio, got {channels} channels", "format"
                )
            rate = reader.getframerate()
            if rate != SUPPORTED_SAMPLE_RATE:
                raise InvalidAudioError(
                    f"expected a 16000 Hz sample rate, got {rate} Hz", "format"
                )
```

With the constants beside `SUPPORTED_SAMPLE_WIDTH`:

```python
SUPPORTED_CHANNELS = 1
SUPPORTED_SAMPLE_RATE = 16000
```

- [ ] **Step 4: Run the full suite**

Run: `uv run --locked pytest -q`
Expected: PASS. `tests/fixtures/hello.wav` and `silence.wav` are already 16 kHz mono — if either fails, the fixture is wrong and must be regenerated, not the check relaxed.

- [ ] **Step 5: Commit**

```bash
git add src/hark/audio.py tests/test_audio.py
git commit -m "[hark] Enforce the documented wire format, not just sample width"
```

---

### Task 4: SPM package skeleton and bundle layout

**Files:**
- Create: `client/agent/Package.swift`, `client/agent/Sources/HarkAgent/main.swift`, `client/agent/Resources/Info.plist`, `client/agent/Resources/Hark.entitlements`, `client/agent/Tests/HarkAgentTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable package. Tasks 5-9 add files under `Sources/HarkAgent/`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HarkAgent",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "HarkAgent", path: "Sources/HarkAgent"),
        .testTarget(name: "HarkAgentTests", dependencies: ["HarkAgent"],
                    path: "Tests/HarkAgentTests"),
    ]
)
```

No external dependencies. Adding one needs a note in the spec first — dependency reduction is the point of the surrounding work.

- [ ] **Step 2: Write `Info.plist`**

Keys: `CFBundleIdentifier` = `com.drycodeworks.hark-agent`, `CFBundleExecutable` = `HarkAgent`, `LSUIElement` = `true`, `LSMinimumSystemVersion` = `13.0`, `NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription`, and `NSAppTransportSecurity` containing **only** `NSAllowsLocalNetworking = true`.

Do **not** add `NSExceptionDomains`. Per-host entries cannot follow `client.json` — the plist is signed, so editing it after download invalidates the signature. Restricting insecure HTTP to IP literals is what makes a static plist sufficient.

- [ ] **Step 3: Write `Hark.entitlements`**

`com.apple.security.device.audio-input` = `true`. Under the hardened runtime, `NSMicrophoneUsageDescription` alone does not permit capture.

- [ ] **Step 4: Smoke test and run**

```swift
import XCTest
@testable import HarkAgent

final class SmokeTests: XCTestCase {
    func testPackageBuilds() { XCTAssertTrue(true) }
}
```

Run: `swift test --package-path client/agent`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add client/agent
git commit -m "[hark] Add the agent package skeleton"
```

---

### Task 5: Config loading and transport policy

**Files:**
- Create: `client/agent/Sources/HarkAgent/Config.swift`, `client/agent/Tests/HarkAgentTests/ConfigTests.swift`

**Interfaces:**
- Consumes: Task 4's package.
- Produces:
  ```swift
  struct Config {
      let serverURL: URL
      let key: String
      static func load(configPath: URL, keyPath: URL) throws -> Config
  }
  enum ConfigError: Error, Equatable {
      case missingConfig, malformedConfig(String)
      case missingKey, keyContainsWhitespace
      case insecureTransport(host: String)
      case userinfoInURL
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
func testRejectsPlainHTTPToAHostname() throws {
    XCTAssertThrowsError(try policy(for: "http://desktop.ts.net:8911/dictate",
                                    allowlist: ["desktop.ts.net"])) { err in
        XCTAssertEqual(err as? ConfigError,
                       .insecureTransport(host: "desktop.ts.net"))
    }
}

func testAllowsPlainHTTPToAnAllowlistedIPLiteral() throws {
    XCTAssertNoThrow(try policy(for: "http://100.64.0.1:8911/dictate",
                                allowlist: ["100.64.0.1"]))
}

func testRejectsPlainHTTPToAnUnlistedIPLiteral() throws {
    XCTAssertThrowsError(try policy(for: "http://100.64.0.2:8911/dictate",
                                    allowlist: ["100.64.0.1"]))
}

func testAllowsLoopbackUnconditionally() throws {
    XCTAssertNoThrow(try policy(for: "http://127.0.0.1:8911/dictate", allowlist: []))
}

func testRejectsUserinfo() throws {
    XCTAssertThrowsError(try policy(for: "http://me@127.0.0.1:8911/dictate",
                                    allowlist: []))
}

func testTrimsTheKeyTrailingNewline() throws {
    // config.py:129 writes `key + "\n"`. Sending raw bytes 401s every request.
    XCTAssertEqual(try readKey(from: "secret-value\n"), "secret-value")
}

func testRejectsAKeyWithEmbeddedWhitespace() throws {
    XCTAssertThrowsError(try readKey(from: "secret value\n"))
}
```

A hostname is *any* host that is not a numeric IP literal. Parse with `IPv4Address`/`IPv6Address`; do not pattern-match on dots.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path client/agent --filter ConfigTests`
Expected: FAIL — `Config` does not exist.

- [ ] **Step 3: Implement `Config.swift`**

`load` reads `client.json` (`server`, `insecure_transport_hosts`), reads the key from `keyPath`, trims surrounding whitespace, rejects embedded whitespace, and applies the transport policy above. It never falls back to a default server.

- [ ] **Step 4: Run tests**

Run: `swift test --package-path client/agent --filter ConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add client/agent/Sources/HarkAgent/Config.swift client/agent/Tests/HarkAgentTests/ConfigTests.swift
git commit -m "[hark] Load client config and enforce the transport policy"
```

---

### Task 6: In-memory recorder

**Files:**
- Create: `client/agent/Sources/HarkAgent/Recorder.swift`, `client/agent/Tests/HarkAgentTests/WAVTests.swift`

**Interfaces:**
- Consumes: Task 4's package.
- Produces:
  ```swift
  enum CaptureOutcome { case audio(Data), noFrames, allSilent, denied, deviceUnavailable }
  actor Recorder {
      func start() async throws
      func stop() async -> CaptureOutcome
  }
  func buildWAV(pcm: Data, sampleRate: Int = 16000, channels: Int = 1) -> Data
  ```

Port `client/rec.swift` and keep three behaviours it already proves correct:

- `rec.swift:65` — switch on `AVCaptureDevice.authorizationStatus(for: .audio)`. **Never** infer permission from a frame count; a denied device returns substituted silence (issue #9, fixed in `559aafe`).
- `rec.swift:78` — `requestAccess` and pump `RunLoop.main` rather than blocking on a semaphore. The completion arrives on an unspecified queue, and a blocked main thread deadlocks.
- `rec.swift:185` — keep the zero-frame check for its real meaning: the device delivered nothing at all.

- [ ] **Step 1: Write the failing WAV tests**

```swift
func testHeaderIsFortyFourBytesAndRIFFWAVE() {
    let wav = buildWAV(pcm: Data(count: 3200))
    XCTAssertEqual(wav.count, 44 + 3200)
    XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
    XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
}

func testSizesAreBackPatchedFromActualLength() {
    // RIFF and data sizes are unknown until release, so they are written last.
    let wav = buildWAV(pcm: Data(count: 3200))
    XCTAssertEqual(le32(wav, at: 4), UInt32(36 + 3200))   // RIFF chunk size
    XCTAssertEqual(le32(wav, at: 40), UInt32(3200))       // data chunk size
}

func testDeclaresSixteenKilohertzMonoSixteenBit() {
    let wav = buildWAV(pcm: Data(count: 320))
    XCTAssertEqual(le16(wav, at: 22), 1)        // channels
    XCTAssertEqual(le32(wav, at: 24), 16000)    // sample rate
    XCTAssertEqual(le16(wav, at: 34), 16)       // bits per sample
    XCTAssertEqual(le32(wav, at: 28), 32000)    // byte rate
    XCTAssertEqual(le16(wav, at: 32), 2)        // block align
}

func testServerAcceptsOurHeader() throws {
    // The bytes this builder emits must satisfy the checks Task 3 added.
    let wav = buildWAV(pcm: Data(count: 3200))
    try wav.write(to: URL(fileURLWithPath: "/tmp/hark-header-test.wav"))
    // Assert via the Python suite in CI; see Task 11.
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path client/agent --filter WAVTests`
Expected: FAIL — `buildWAV` does not exist.

- [ ] **Step 3: Implement `buildWAV` and the recorder**

Capture is owned by an `actor`, so the audio-thread tap and main-queue stop cannot race. `rec.swift:163` mutates `framesWritten` from the tap while `:185` reads it from `stop()` — unsynchronised today and more consequential in-process. `stop()` waits for the tap to drain and is idempotent.

- [ ] **Step 4: Run tests**

Run: `swift test --package-path client/agent --filter WAVTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add client/agent/Sources/HarkAgent/Recorder.swift client/agent/Tests/HarkAgentTests/WAVTests.swift
git commit -m "[hark] Capture in-process and build the WAV in memory"
```

---

### Task 7: Dictate client — bounds, sanitisation, error mapping

**Files:**
- Create: `client/agent/Sources/HarkAgent/DictateClient.swift`, `client/agent/Sources/HarkAgent/Sanitize.swift`, `client/agent/Tests/HarkAgentTests/DictateClientTests.swift`, `client/agent/Tests/HarkAgentTests/SanitizeTests.swift`

**Interfaces:**
- Consumes: `Config` (Task 5).
- Produces:
  ```swift
  enum DictateError: Error, Equatable {
      case unreachable(String), badKey(String), clientBug(String)
      case badAudio(String), whisperDown(String), unexpected(Int, String)
      case responseTooLarge, malformedResponse
  }
  func sanitize(_ raw: String) -> String
  struct DictateClient { func send(wav: Data) async throws -> String }
  ```

- [ ] **Step 1: Write the failing sanitisation tests**

`sanitize.py:23` runs on the server, and revision 1 wrongly treated that as sufficient. A compromised server — or anyone on the network path of a plaintext two-machine setup — returns JSON the server's sanitiser never touched, and "Never Return" protects nothing when the payload itself carries `\n`.

```swift
func testCollapsesNewlinesToSpaces() {
    XCTAssertEqual(sanitize("rm -rf /\nyes"), "rm -rf / yes")
}

func testStripsC0AndC1Controls() {
    XCTAssertEqual(sanitize("a\u{1B}[31mb"), "a [31mb")
    XCTAssertEqual(sanitize("a\u{9B}b"), "a b")
}

func testStripsUnicodeLineSeparators() {
    XCTAssertEqual(sanitize("a\u{2028}b\u{2029}c"), "a b c")
}

func testControlBetweenWordsSeparatesRatherThanFuses() {
    // Substituting a space, not deleting, keeps two words two words.
    XCTAssertEqual(sanitize("one\u{0}two"), "one two")
}

func testMatchesThePythonImplementation() {
    // Same cases as tests/test_sanitize.py. The two must not drift.
    XCTAssertEqual(sanitize("  hello   world  "), "hello world")
    XCTAssertEqual(sanitize("\r\n"), "")
}
```

- [ ] **Step 2: Write the failing transport tests**

```swift
func testRejectsABodyOverOneMebibyteBeforeDecoding() async {
    let stub = StubProtocol.respond(status: 200, body: Data(count: 1_048_577))
    await XCTAssertThrowsErrorAsync(try await client(stub).send(wav: tinyWAV)) {
        XCTAssertEqual($0 as? DictateError, .responseTooLarge)
    }
}

func testRejectsTranscriptOverEightKibibytes() async {
    let text = String(repeating: "a", count: 8193)
    let stub = StubProtocol.respond(status: 200, json: ["text": text])
    await XCTAssertThrowsErrorAsync(try await client(stub).send(wav: tinyWAV))
}

func testFourHundredIsAClientFormatBugNotAMicrophoneProblem() async {
    let stub = StubProtocol.respond(status: 400, json: ["detail": "not a readable WAV"])
    await XCTAssertThrowsErrorAsync(try await client(stub).send(wav: tinyWAV)) {
        guard case .badAudio(let msg)? = $0 as? DictateError else { return XCTFail() }
        XCTAssertFalse(msg.lowercased().contains("microphone"))
    }
}

func testSanitisesAndBoundsTheErrorDetail() async {
    let stub = StubProtocol.respond(status: 503, json: ["detail": "down\nnow"])
    await XCTAssertThrowsErrorAsync(try await client(stub).send(wav: tinyWAV)) {
        guard case .whisperDown(let msg)? = $0 as? DictateError else { return XCTFail() }
        XCTAssertEqual(msg, "down now")
    }
}

func testDoesNotFollowRedirects() async {
    let stub = StubProtocol.redirect(to: "https://evil.example/dictate")
    await XCTAssertThrowsErrorAsync(try await client(stub).send(wav: tinyWAV))
}
```

The 1 MiB bound must bind **before** JSON decoding — a post-decode cap still lets a hostile server make `URLSession` buffer an unbounded body. Use `URLSession.bytes(for:)` and abort past the limit.

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --package-path client/agent --filter "DictateClientTests|SanitizeTests"`
Expected: FAIL — neither type exists.

- [ ] **Step 4: Implement both**

`DictateClient` uses an **ephemeral** `URLSession` (no on-disk credential or response cache) with a delegate that cancels redirects. Reject, never truncate: rejection is visible, truncation silently corrupts a transcript.

- [ ] **Step 5: Run tests**

Run: `swift test --package-path client/agent`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add client/agent/Sources/HarkAgent/DictateClient.swift client/agent/Sources/HarkAgent/Sanitize.swift client/agent/Tests/HarkAgentTests
git commit -m "[hark] Bound and sanitise every server response"
```

---

### Task 8: Hotkey binding

**Blocked by Task 1.** Implement only the mechanism the spike selected.

**Files:**
- Create: `client/agent/Sources/HarkAgent/Hotkey.swift`, `client/agent/Tests/HarkAgentTests/HotkeyTests.swift`

**Interfaces:**
- Consumes: Task 1's verdict.
- Produces:
  ```swift
  enum HotkeyError: Error { case registrationFailed(String), chordUnavailable }
  final class Hotkey {
      init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void)
      func register() throws
      func unregister()
      var isRegistered: Bool { get }
  }
  ```

`register()` is called by the installer after Hammerspoon exits, **not** at launch — see Task 13's cutover ordering.

- [ ] **Step 1: Write the failing tests**

Only the observable contract is unit-testable; real delivery is not.

```swift
func testStartsUnregistered() {
    XCTAssertFalse(Hotkey(onPress: {}, onRelease: {}).isRegistered)
}

func testRegistrationFailureIsReportedNotSwallowed() throws {
    // The failure this replaces: hs.hotkey.bind returns success and then
    // silently never fires. Registration must be observable.
    let h = Hotkey(onPress: {}, onRelease: {})
    try h.register()
    XCTAssertTrue(h.isRegistered)
    h.unregister()
    XCTAssertFalse(h.isRegistered)
}
```

- [ ] **Step 2: Run to verify they fail, implement, re-run**

If Carbon was selected, pass `kEventHotKeyExclusive` — without it, registration succeeds even when another app owns the chord (`CarbonEvents.h`), and migration can claim nothing about ownership.

- [ ] **Step 3: Commit**

```bash
git add client/agent/Sources/HarkAgent/Hotkey.swift client/agent/Tests/HarkAgentTests/HotkeyTests.swift
git commit -m "[hark] Bind the hotkey with the mechanism the spike selected"
```

---

### Task 9: Agent controller — state machine, permissions, paste, status

**Blocked by Tasks 5, 6, 7, 8.**

**Files:**
- Create: `client/agent/Sources/HarkAgent/AgentController.swift`, `client/agent/Sources/HarkAgent/StatusFile.swift`, `client/agent/Tests/HarkAgentTests/StateMachineTests.swift`, `client/agent/Tests/HarkAgentTests/StatusFileTests.swift`
- Modify: `client/agent/Sources/HarkAgent/main.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: the running agent.

- [ ] **Step 1: Write the failing state-machine tests**

```swift
func testPressOutsideIdleIsIgnored() { /* recording -> press -> still one capture */ }

func testStoppingBlocksASecondCaptureUntilDrainCompletes() {
    // Without `stopping`, a press right after release either overlaps
    // captures or drops the utterance.
}

func testStartingAbortsAfterFiveSecondsWithNoFirstBuffer() {
    // rec.swift:139 arms its ceiling only after the first buffer, so a device
    // that never delivers one hangs forever. This deadline is separate from
    // the 120 s capture cap.
}

func testCaptureCapUploadsWhatWasCaptured() { /* 120 s -> stop, upload, notice */ }

func testLateResponseFromAPreviousSequenceIsDiscarded() {
    // A timed-out request that completes late must not paste into a newer
    // capture's turn.
}

func testPasteWithheldWhenFrontmostApplicationChanged() {
    // Application granularity only. This does NOT catch a focus move within
    // an app; do not assert that it does.
}

func testNoCommandVWhenThePasteboardWriteFailed() {
    // Otherwise ⌘V pastes whatever was on the clipboard before.
}

func testClipboardSelfClearsAfterNinetySecondsOnlyIfChangeCountUnchanged() {}
```

- [ ] **Step 2: Write the failing status-file tests**

```swift
func testProcessStartedIsTheVerbatimPsString() {
    // `ps -o lstart=` prints "Fri Jul 31 14:02:11 2026" — localised, non-ISO.
    // Storing what ps prints makes --doctor a trimmed string comparison
    // instead of brittle date parsing.
    XCTAssertFalse(StatusFile.current().processStarted.contains("T"))
}

func testWrittenEpochIsAnInteger() {}

func testCarriesHotkeyAndLoginItemState() {
    // A heartbeat without these passes while the product does not work.
}

func testWriteIsAtomic() {
    // temp file + rename; --doctor must never read partial JSON.
}
```

- [ ] **Step 3: Run to verify they fail, implement, re-run**

Permissions: `AVCaptureDevice.authorizationStatus` + `requestAccess` at launch (the Microphone pane has no "+" button and lists only apps that have already asked), and `AXIsProcessTrustedWithOptions` **with the prompt option** — `AXIsProcessTrusted` alone never prompts, leaving a fresh install no path to the grant. Re-read permissions after wake and on activation so revocation mid-session is reflected.

`SMAppService.mainApp.register()` is **not** called here. It is the installer's last cutover step (Task 13).

- [ ] **Step 4: Commit**

```bash
git add client/agent/Sources/HarkAgent client/agent/Tests/HarkAgentTests
git commit -m "[hark] Add the agent state machine, permissions and status heartbeat"
```

---

### Task 10: Menu bar status item

**Files:**
- Create: `client/agent/Sources/HarkAgent/StatusItem.swift`

**Interfaces:** Consumes `AgentController`. Produces no API.

Icon states: idle, recording, error. Menu: **Quit only.**

Do not add "Reload config" or "Run diagnostics". `install-client.sh --doctor` is already the diagnostic interface, and a second one drifts from it.

- [ ] **Step 1: Implement, verify by running the app, commit**

```bash
git add client/agent/Sources/HarkAgent/StatusItem.swift
git commit -m "[hark] Show agent state in the menu bar"
```

---

### Task 11: CI build, sign, notarise, release

**Files:**
- Modify: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`, `client/agent/scripts/make-bundle.sh`

**Interfaces:** Produces the release artifact Task 12 downloads.

- [ ] **Step 1: Add Swift to CI**

`swift build` and `swift test --package-path client/agent` on `macos-latest`. Add a cross-check that `buildWAV`'s output passes the Python validators from Task 3 — one bug class, two languages, caught in CI rather than in the field.

- [ ] **Step 2: Write the release workflow**

Assemble `Hark.app` from the SPM product plus `Info.plist` and entitlements; sign with Developer ID **and hardened runtime**; notarise; **`xcrun stapler validate`** — the only place `stapler` is used, because it ships with Xcode and the client must not need it. Publish a universal (arm64 + x86_64) zip.

CI must keep the **designated requirement** stable across releases and certificate rotation. TCC binds to that, not to "Team ID plus bundle ID" loosely.

- [ ] **Step 3: Verify with a prerelease tag, then commit**

```bash
git add .github/workflows client/agent/scripts
git commit -m "[hark] Build, sign and notarise the agent in CI"
```

---

### Task 12: Installer — download and verify

**Files:**
- Modify: `install-client.sh` (replace the Hammerspoon install and the `swiftc` build at `:419`)
- Test: `tests/test_install_client_verify.py`

**Interfaces:** Consumes Task 11's artifact. Produces a verified `~/Applications/Hark.app`.

- [ ] **Step 1: Write the failing tests**

Follow `tests/test_install_server_doctor.py`'s pattern: source the script behind its guard and stub the network.

```python
def test_refuses_an_artifact_with_the_wrong_team_id(): ...
def test_sets_quarantine_before_assessing(): ...
def test_leaves_the_existing_install_untouched_on_failure(): ...
def test_relaunches_the_previous_bundle_on_rollback(): ...
```

- [ ] **Step 2: Implement**

Stage to a temp dir. **Set `com.apple.quarantine` on the extracted app explicitly** — a `curl` + `ditto` flow need not preserve it the way a browser does, and without it `spctl` takes a weaker path, so the notarisation check would quietly not be the check it claims. Then:

```bash
spctl --assess --type execute -vv "$STAGED_APP"
codesign --verify --deep --strict -R "$EXPECTED_REQUIREMENT" "$STAGED_APP"
```

Both are stock macOS binaries. **Never** call `xcrun` or `stapler` here.

Keep the previous bundle until the new one reports a healthy heartbeat; on failure restore **and relaunch** it.

- [ ] **Step 3: Run tests and commit**

```bash
git add install-client.sh tests/test_install_client_verify.py
git commit -m "[hark] Install the agent from a verified release artifact"
```

---

### Task 13: Installer — staged migration off Hammerspoon

**Files:**
- Create: `client/legacy/init-v1.lua`
- Modify: `install-client.sh`, `client/init.lua` (becomes a silent no-op stub)
- Test: `tests/test_install_client_migration.py`

**Interfaces:** Consumes Task 12. Produces a completed cutover.

**`client/legacy/init-v1.lua` is a verbatim copy of the last functional Lua client, committed in the SAME commit that stubs `client/init.lua`.** It cannot be copied at install time: by then the user has pulled and `client/init.lua` *is* the stub, and after a repo move the symlink is dangling and resolves to nothing. Add a test asserting the legacy asset still binds a hotkey, so a later tidy-up cannot silently empty the rollback target.

- [ ] **Step 1: Write the failing tests**

```python
def test_legacy_asset_still_binds_a_hotkey(): ...
def test_detects_ownership_only_from_pre_existing_evidence(): ...
def test_asks_before_acting_when_only_the_dangling_heuristic_matches(): ...
def test_does_not_touch_an_independently_managed_hammerspoon_config(): ...
def test_rollback_unregisters_the_login_item_before_relaunching(): ...
def test_writes_the_ownership_record_only_after_success(): ...
```

- [ ] **Step 2: Implement the cutover in this exact order**

0. Stage `client/legacy/init-v1.lua` → `~/.config/hark/legacy-client.lua`; confirm readable.
1. Detect from **pre-existing evidence only**: a record from an *earlier* run whose recorded target matches the current symlink target; else the marker comment in the target; else a dangling symlink matching a known layout — **a heuristic, so require explicit confirmation when it is the sole evidence.**
2. Install and health-check the agent with the hotkey **disabled** and login registration **not performed**.
3. Quit Hammerspoon; wait for process exit. Chord ownership cannot be queried, so process exit is the strongest available signal.
4. Tell the agent to register the hotkey, verify, **then** `SMAppService.mainApp.register()`.
5. On failure at 4: stop the agent, ensure the login item is **not** registered, point the symlink at `~/.config/hark/legacy-client.lua`, relaunch Hammerspoon, confirm running, report.
6. On success only: write the ownership record, remove the symlink, offer `tccutil reset` for **Accessibility, Microphone and ListenEvent**.
7. If revocation is declined, say plainly the original exposure remains.

Registration is last because a rolled-back install that still registered would start at next login and fight the restored Hammerspoon.

- [ ] **Step 3: Run tests and commit**

```bash
git add client/legacy/init-v1.lua client/init.lua install-client.sh tests/test_install_client_migration.py
git commit -m "[hark] Cut over from Hammerspoon with a working rollback"
```

---

### Task 14: Installer — rewrite `--doctor`

**Files:** Modify `install-client.sh` (`:86`, `:127`, `:173`, `:196`, `:679`, `:742`). Test: `tests/test_install_client_doctor.py`.

Replace every Hammerspoon-era check. New checks: bundle exists and verifies; agent running; heartbeat fresh (**PID alive, `ps -o lstart=` matches `process_started` after trimming, `written_epoch` within 90 s**); `hotkey` registered; `login_item` enabled; permissions authorised; server reachable; key authenticates.

No agent running is a **FAIL**, not a skipped check. Warn on every `insecure_transport_hosts` entry, naming the assumption it encodes.

Stop passing the key in argv (`:313`) — any local account can read it from the process table.

- [ ] **Step 1: Write the failing tests, implement, run, commit**

```bash
git add install-client.sh tests/test_install_client_doctor.py
git commit -m "[hark] Rewrite --doctor for the native agent"
```

---

### Task 15: Documentation

**Files:** Modify `README.md` (`:16`, `:138`, `:175`, `:250`, `:387`), `docs/superpowers/specs/2026-07-14-hark-open-source-design.md:7`, `client/hark-config.example.lua` → `client/client.json.example`. Delete `client/rec.swift`, `tests/test_client_record.lua`.

**Do not delete `client/rec.swift` before Task 13 lands** — `install-client.sh:426` still compiles it, and removing it first bricks the installer mid-run.

README must state, in the same terms the spec uses: the paste guarantee is **application-granularity only** (it does not catch a focus move within an app), and the clipboard **self-clears after 90 s** as a privacy property, not only as paste-recovery ergonomics.

Update `:7`'s "(architecture unchanged)". `ef47aeb` already struck the CI and native-app non-goals; `c852392` already fixed the `setup.sh` references — do not redo either.

- [ ] **Step 1: Update docs, verify counts against a real run, commit**

```bash
git add README.md docs client
git commit -m "[hark] Document the native client"
```

---

## Self-review

**Spec coverage.** Every spec section maps to a task: Phase 0 → 1; server blast radius → 2, 3; architecture → 4-7, 9, 10; hotkey → 1, 8; state machine → 9; status/`--doctor` → 9, 14; release contract → 11, 12; migration → 13; docs → 15. Clipboard retention → 9. Transport → 5. Response bounds → 7.

**Known gaps, stated rather than hidden.** The Keychain-pinned server origin is deliberately out of scope — it is recorded as a spec follow-up and needs its own design; a same-UID rewrite of `client.json` can still redirect the agent. Nothing here proves TCC survives a Developer ID *certificate rotation*; that only shows up at the second release.

**Verification status.** The Python code blocks in Tasks 2 and 3 are against code read at `8d12f7b` and are expected to run as written. The Swift blocks are **specifications, not compiled code** — no Swift here was built or run. Treat signatures as the contract and fix compile errors in place; report any that force an interface change rather than silently diverging.
