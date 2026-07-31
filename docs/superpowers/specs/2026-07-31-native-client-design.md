# Native client design — replacing the Hammerspoon Lua client

Issue: [DRYCodeWorks/hark#2](https://github.com/DRYCodeWorks/hark/issues/2)
Date: 2026-07-31
Revision: 2, after a six-reviewer panel returned 6/6 REVISE on revision 1

## Why

`install-client.sh:573` links `~/.hammerspoon/init.lua` to this repo's `client/init.lua`.
Hammerspoon has exactly one config file, so installing hark claims it.

The permission story matters more than the tidiness one. Accessibility is granted to
Hammerspoon, not to hark. That is a general-purpose scriptable Lua runtime holding a grant
that can observe every keystroke, and its config is a symlink into a git repo, so `git
pull` changes what that grant covers without re-prompting.

What Hammerspoon buys in return is a **stable signed TCC identity**. hark rides on an
already-trusted app by swapping a text file. Taking that away means hark owns the identity
problem itself, which is why this design assumes a Developer ID rather than deferring it.

## What revision 1 got wrong

Recorded because the errors are instructive, not to pad the document.

**The hotkey rationale was wrong.** Revision 1 argued for Carbon `RegisterEventHotKey`
because it "asks for permission to type, not permission to watch you type." Synthesising
⌘V requires Accessibility, and Accessibility is a single atomic grant — holding it also
permits creating a `CGEventTap`. The claimed saving does not exist as stated.

**The collision claim was wrong.** Revision 1 said `RegisterEventHotKey` errors when
another app owns the chord. The installed SDK says the opposite:

> "The same hot key can, however, be registered by multiple applications... In Mac OS X
> 10.5 and later, you can request exclusive registration for your process only by passing
> `kEventHotKeyExclusive` for the `inOptions` parameter."
> — `CarbonEvents.h`, `RegisterEventHotKey` discussion

**One claim was fabricated.** Revision 1 said `tests/test_audio.py` pins the wire format.
It does not: `audio.py:44-49` validates sample width only, so a stereo or 44.1 kHz WAV is
accepted today. Fixing that is now in scope (see Testing).

**The mechanism question is therefore unresolved**, and revision 2 does not pre-decide it.
See Phase 0.

## Decisions

| Question | Decision |
|---|---|
| Signing | **Developer ID assumed.** CI builds, signs and notarises; releases ship an artifact |
| Install | `install-client.sh` downloads and installs the artifact. It no longer compiles |
| App shape | `LSUIElement` bundle, menu bar status item, at `~/Applications/Hark.app` (no sudo) |
| Capture | Absorbed in-process; `rec` as a separate child binary goes away |
| Config | `~/.config/hark/client.json` holds the **server URL only**; the key always lives in `~/.config/hark/key` mode 600 |
| Hotkey | **Undecided — Phase 0 spike decides.** Carbon and `CGEventTap` are both live |
| Migration | Quit Hammerspoon and offer to revoke its grants. Delete nothing from `$HOME` |

### Developer ID changes the shape of the problem

Revision 1 measured that identical Swift sources produce a different CDHash on every
build, and built an installer-side input hash to avoid re-signing on every re-run.

That whole mechanism is **deleted**. With CI producing the binary, the installer never
compiles, so re-running it cannot mint a new CDHash. With Developer ID, TCC keys on Team ID
plus bundle ID rather than the hash, so grants survive updates. The measurement stands as
the justification for requiring Developer ID; it is no longer a constraint to engineer
around.

Two consequences worth stating plainly:

- Notarisation is not optional. A downloaded `.app` carries `com.apple.quarantine`, and an
  un-notarised quarantined app is blocked outright on current macOS. Telling users to
  `xattr -d` is the kind of friction this project avoids everywhere else.
- The client install no longer needs the Xcode command line tools. That removes a
  multi-gigabyte dependency from the machine you dictate *from*, which is the point of the
  wider dependency work (#3, #4, #5).

`~/Applications` keeps the install sudo-free. Under Developer ID, TCC is keyed on the
signing identity rather than the path, so location is a packaging choice, not a permission
one.

## Phase 0: the hotkey spike (gates everything else)

Two questions decide the mechanism. Both are unresolved and neither should be answered by
argument.

1. **Does a keyboard `CGEventTap` require Input Monitoring in addition to Accessibility?**
   `README.md:245-247` states from this project's own experience that an `hs.eventtap`
   watching `flagsChanged` needs Input Monitoring. If that holds for a keyDown/keyUp tap,
   Carbon is one grant and the tap is two, and the permission argument survives revision
   1's bad reasoning by a different route. If it does not hold, the tap is free.
2. **Is `kEventHotKeyReleased` reliable enough for hold-to-talk?** Specifically under load,
   and when the user rolls onto other modifiers mid-hold.

Build both, measure both, then write the mechanism into this document. Revision 1's
"`CGEventTap` documented as the fallback" is removed: pre-designing an unused branch is
speculative work, and if Carbon loses the spike the affected sections get rewritten
against what actually won.

Whichever wins, the agent must detect and report its own failure to register rather than
going silent, because silence is the failure mode this project keeps designing against.
Carbon additionally requires `kEventHotKeyExclusive` if collision detection is wanted.

## Architecture

One SPM package. CI runs `swift build` and `swift test`; the release job produces the
signed, notarised `Hark.app`.

Bundle ID `com.drycodeworks.hark-agent`. This is a **new** identifier that follows the
existing launchd label style; it is not an existing label. `Info.plist` carries
`LSUIElement`, `NSMicrophoneUsageDescription`, and the ATS declaration below. Login start
uses `SMAppService.mainApp`, setting the floor at macOS 13.

| File | Responsibility |
|---|---|
| `Config.swift` | Load `client.json`; read and trim the key file; enforce the transport policy |
| `Hotkey.swift` | Register the chord (mechanism per Phase 0); press/release; registration failure |
| `Recorder.swift` | AVAudioEngine capture, format conversion, in-memory WAV, capture-state reporting |
| `DictateClient.swift` | POST, decode, map status to typed errors, sanitise the response |
| `AgentController.swift` | The state machine, permissions, paste, status file, logging, menu bar |

Revision 1 had eight files. `Paster`, `Log`, `Diagnostics` and `StatusItem` each had one
caller and no independent policy, so they collapse into `AgentController`. The three
remaining seams — config, capture, transport — are the ones with real test surface.

The status item shows state and offers Quit only. "Reload config" and "Run diagnostics"
are removed; `install-client.sh --doctor` is already the diagnostic interface and a second
one would drift from it.

### Capture, permissions, and a possible live bug

Revision 1 said "zero frames captured" indicates missing microphone permission. That is how
`rec.swift:128` works today, and a reviewer asserts it is wrong: that a TCC-denied
`AVAudioEngine` delivers the expected buffers filled with **silence** rather than no
buffers, so the frame count never reaches zero.

If that is correct, it is a live defect in shipped code, not merely a flaw in this design:
`rec.swift`'s exit-3 path would never fire, `init.lua:486-496`'s probe would always report
`ok`, and `--doctor`'s microphone check would be a confident false PASS. **Phase 0 must
verify this against a genuinely denied grant**, and if confirmed it gets its own issue
against the current client.

Either way the design does not rely on frame counts for permission:

- Query `AVCaptureDevice.authorizationStatus(for: .audio)` explicitly, and call
  `requestAccess` at first launch to raise the consent dialog. The Microphone pane has no
  "+" button and only lists apps that have already asked, so the request must happen.
- Probe at **launch**, not at first hotkey press, so a clean install has an
  agent-authored status before anyone runs `--doctor`.
- Treat an all-silent buffer as its own reportable condition, distinct from a denied grant.

Accessibility uses `AXIsProcessTrustedWithOptions` with the prompt option at first launch.
`AXIsProcessTrusted` alone only checks and never prompts, which leaves a fresh install with
no path to the grant.

### The WAV is built in memory

`/tmp/hark.wav` goes away, and with it the stale-file hazard `init.lua:357` guards against.
`AVAudioFile` writes to a URL, so `Recorder` builds the 44-byte header itself.

The RIFF and data chunk sizes depend on total length, which is unknown until release, so
the header is written last or back-patched before the POST. Getting this wrong produces a
server 400, which is exactly why the 400 mapping below had to change.

### Capture must be serialised

The tap callback runs on an audio thread while key-up runs on the main queue.
`rec.swift:112` mutates `framesWritten` from the callback while `rec.swift:128` reads it
from `stop()` — an existing unsynchronised access that becomes more consequential in-process.

Define an explicit boundary: an actor or serial queue owning the buffer, with stop waiting
for the tap to drain before the WAV is finalised. Stop must be idempotent.

## State machine

Revision 1 said only "return early if already recording", which leaves both a stuck-state
and an ordering hole.

```
idle ──press──► starting ──first buffer──► recording ──release──► stopping
  ▲                                                                   │
  └──────────── paste / error ◄──── uploading ◄──── drain complete ────┘
```

Rules:

- A press outside `idle` is ignored.
- `stopping` exists so a press immediately after release cannot start a second capture
  while the first is still draining. Revision 1 would have either overlapped captures or
  dropped the second utterance.
- **One in-flight request.** `init.lua:319` clears its task before the async POST, so today
  two quick utterances can paste in reverse order. Serialise: no new capture while a
  request is pending, and drop a response whose sequence number is not current.
- **Maximum capture duration.** A missed release must not leave the engine running. In
  memory this is unbounded growth rather than a growing file, so the cap stops capture and
  returns to `idle`.
- Cleanup on sleep, app deactivation, and termination.

## Data flow

1. Press. Ignore unless `idle` and the key resolves.
2. Capture starts; status item and overlay show recording.
3. Release. Tap drains, WAV finalised in memory.
4. No frames, or all-silent buffers: report the capture-side cause and stop. Do not POST.
5. POST with `X-Hark-Key` and `Content-Type: audio/wav`.
6. `200` with empty text: transient "heard nothing", paste nothing. Not an error.
7. `200` with text: **sanitise, then** set the pasteboard, verify the write, then ⌘V.

Never Return. The clipboard is deliberately not restored.

### The client sanitises the response

The server sanitises at `sanitize.py:23`, and revision 1 treated that as sufficient. It is
not. A compromised server, or anyone on the network path of a plaintext two-machine setup,
returns JSON the server's sanitiser never touched. "Never Return" protects nothing when the
payload itself carries `\r` or `\n` into a terminal without bracketed paste.

`DictateClient` applies the same rule as `sanitize.py` — C0/C1 controls and Unicode line
separators replaced with a space, whitespace collapsed — plus a length cap, before the text
reaches the pasteboard. The server keeps its sanitiser; this is defence in depth, and the
Swift and Python implementations get the same test cases.

If the pasteboard write fails, report it and **do not** synthesise ⌘V — otherwise the
keystroke pastes whatever was on the clipboard before, potentially into a terminal.

## Transport policy

The two-machine default is plaintext HTTP (`install-client.sh:503`) over what
`README.md:214` calls "a LAN address you trust". On that path an attacker reads the audio,
the transcript and `X-Hark-Key`, and can forge the response that the client then types.

`Config` enforces:

- plain HTTP permitted **only** for numeric loopback,
- HTTPS required for every other host,
- userinfo (`user@host`) rejected — `install-client.sh:230` already treats it as a defect,
- redirects not followed,
- an ephemeral `URLSession` so credentials and responses are not cached to disk.

`Info.plist` declares the matching ATS exception. Revision 1 omitted ATS entirely, which
would have produced a client that captures audio and then fails every POST.

Two-machine users on Tailscale who want to keep HTTP need an explicit, documented opt-in;
it is not the default.

## Configuration

`client.json` holds the server URL. The key always lives at `~/.config/hark/key`, mode
600, written by whichever installer obtained it. Revision 1's inline-versus-file branch is
deleted: one path, one permission contract, nothing to drift.

- `install-client.sh` creates `~/.config/hark` mode 700 before writing anything. On a
  two-machine *client* the directory does not otherwise exist, because the server-side
  `mkdir` ran on the other machine.
- The key file is read and **trimmed**: `config.py:129` writes `key + "\n"` and
  `install-client.sh:427` strips it today. Sending the raw bytes 401s every request.
  Reject embedded whitespace rather than silently trimming it.
- `client.json` is serialised by a real JSON encoder and replaced atomically. The current
  heredoc at `install-client.sh:541` validates quotes only in the key (`:468`), so a
  hand-entered URL containing a quote produces an unparseable file.
- `--doctor` must stop passing the key in argv (`install-client.sh:291`), where any local
  account can read it from the process table. Use a config-file-fed curl or the agent.

**Known residual risk.** Any same-UID process can rewrite `client.json` and point the
trusted agent at an attacker's server; mode 600 does not prevent this. Under Developer ID
the mitigation is available — pin the approved origin in a Keychain item protected by code
identity, and require in-app confirmation to change it. Recorded as a follow-up rather than
built now, because it needs its own design.

## Error handling

| Condition | Message names |
|---|---|
| Connection / transport failure | The URL, and that hark may not be running |
| 401 | Key mismatch, and the file to fix |
| 415 | A client bug, not a microphone problem |
| **400** | **Malformed or unsupported audio — a client format bug.** Show the server's `detail` |
| 503 | whisper-server down, `/tmp/hark-whisper.err` |
| Other | Status code and the server's `detail` |
| No frames / all silent | Capture-side: device selection and microphone permission |

Revision 1 carried `init.lua`'s "400 means microphone permission" across unchanged. That is
now wrong twice over: capture failures never reach the server, and `app.py:98-103` returns
400 for **every** `InvalidAudioError` — including a malformed header this client now builds
by hand. Sending users to Microphone settings for a header bug would be actively
misleading.

Messages render in a borderless transient overlay rather than Notification Center, since a
muted notification is a silent failure.

## Status file

The agent writes `~/.config/hark/client-status.json`; `--doctor` reads it. `--doctor` must
not run the agent binary itself: a probe launched from the terminal tests the *terminal's*
TCC grant and produces a confident false PASS, which is the trap `install-client.sh:183-190`
already documents.

Revision 1 said "only the path changes". Two things must also change:

- **Atomic write** — temp file plus rename. `--doctor` reading mid-write would otherwise
  see partial JSON.
- **Generation stamp** — the file records the agent launch it came from, and `--doctor`
  rejects a status older than the running agent. Today `install-client.sh:200-204` accepts
  any existing `ok` first line, so a stale file survives a revoked grant and reports PASS.

## Testing

Unit-testable with no permissions and no microphone: config loading, key trimming and
rejection, transport-policy enforcement, the WAV header builder (including back-patched
sizes), the status-to-error mapping via a stubbed `URLProtocol`, and **hostile response
sanitisation** — control characters, newlines, Unicode line separators, over-length text.

Server-side, fix the coverage revision 1 wrongly claimed existed: `audio.py` validates
sample width only, so add explicit assertions and server rejection for channel count and
sample rate alongside bit depth.

CI runs `swift build`, `swift test`, and the existing pytest suite.

Not testable in CI, stated as plainly as the README states its own limits: TCC grants, real
hotkey delivery, real paste into a real window.

## Migration

**Nothing is deleted from the user's home directory.** But "report and move on" is not
enough, for two reasons the panel found:

- A running Hammerspoon holds the old Lua **in memory**. Replacing the symlinked file
  changes nothing until it reloads, so both clients bind ⌃⌥Space and fight.
  `install-client.sh:586` already documents that Hammerspoon does not auto-reload.
- Leaving Hammerspoon's Accessibility and Microphone grants in place preserves exactly the
  privilege escape that motivates this issue. Any same-UID process can later rewrite the
  symlink target and reload it.

So `install-client.sh`:

1. quits Hammerspoon and confirms it no longer owns the chord before starting the agent,
2. offers `tccutil reset Accessibility org.hammerspoon.Hammerspoon` and the Microphone
   equivalent, and prints how to remove the cask,
3. reports leftover artifacts without deleting them.

`client/init.lua` becomes a **silent** no-op stub. Revision 1 had it show an alert, which
would fire from a still-running Hammerspoon that the installer is already handling.

## Blast radius

Revision 1 under-specified this and the panel enumerated it. All of the following are in
scope for the implementation, not follow-ups:

- **`install-client.sh`** — replace the Hammerspoon install, the `swiftc` build
  (`:397-408`), the launch/relaunch block (`:576-589`), and every `--doctor` check
  (`:86-110`, `:127`, `:173`, `:192`, `:657`, `:720`). Ordering matters: removing
  `client/rec.swift` while `:404` still compiles it bricks the installer mid-run.
- **`README.md`** — architecture (`:13-14`), install (`:118-135`), `--doctor` (`:155-166`),
  hotkey editing (`:230-247`), two-machine setup, and the repo layout (`:365-367`).
- **Retire** `client/rec.swift`, `tests/test_client_record.lua`, and
  `client/hark-config.example.lua`, replaced by a `client.json` example.
- **Mark superseded** `docs/superpowers/specs/2026-07-14-hark-open-source-design.md`. Three
  of its statements stop being true:
  - `:5` — "(architecture unchanged)", a parenthetical that this design invalidates.
  - `:212-213` — "Replacing Hammerspoon with a native Swift menubar app" listed as a
    non-goal, which is now the goal. Its stated reason ("it would be the right answer for a
    *product*; this is not one") deserves an explicit answer rather than silent reversal.
  - `:210` — "CI, release automation, versioning, changelogs" listed as a non-goal. #1
    already added CI, and this design adds signed release automation. Stale independently
    of the native client.
- Update the status line of `2026-07-14-dictate-design.md` (`:10`), still "Design approved,
  pending implementation plan".

## Non-goals

- The Fn/🌐 key. Revisit only if Phase 0 selects a tap.
- Pre-warming the audio engine. In-process capture makes it possible; the README's privacy
  trade-off is deliberate and stands.
- Streaming transcription and auto-submit, per the 2026-07-14 spec.
- Keychain-pinned server origin. Recorded above as a follow-up.

## Open questions

- Phase 0's two answers, which decide the hotkey mechanism.
- Whether TCC-denied capture really yields silent buffers rather than no frames. If yes,
  file a separate issue against the current client.
- Whether the clipboard should self-clear after a timeout when `changeCount` is unchanged.
  Any local process can poll `NSPasteboard` and harvest every transcript without holding
  any TCC grant. Revision 1 documented non-restoration purely as a usability choice; it is
  also a privacy exposure and the README should say so either way.
