# Native client design — replacing the Hammerspoon Lua client

Issue: [DRYCodeWorks/hark#2](https://github.com/DRYCodeWorks/hark/issues/2)
Date: 2026-07-31
Revision: 3. Round 1 returned 6/6 REVISE; round 2 returned 5 REVISE / 1 APPROVED.

## Why

`install-client.sh:573` links `~/.hammerspoon/init.lua` to this repo's `client/init.lua`.
Hammerspoon has exactly one config file, so installing hark claims it.

The permission story matters more. Accessibility is granted to Hammerspoon, not to hark:
a general-purpose scriptable Lua runtime holds a grant that can observe every keystroke,
and its config is a symlink into a git repo, so `git pull` changes what that grant covers
without re-prompting.

What Hammerspoon buys in return is a **stable signed TCC identity**. Taking that away means
hark owns the identity problem itself, which is why this design assumes a Developer ID.

## What earlier revisions got wrong

**Revision 1's hotkey rationale.** It argued for Carbon `RegisterEventHotKey` because it
"asks for permission to type, not permission to watch you type." Synthesising ⌘V requires
Accessibility, and Accessibility is a single atomic grant that also permits creating a
`CGEventTap`. The claimed saving does not exist as stated.

**Revision 1's collision claim.** It said `RegisterEventHotKey` errors when another app
owns the chord. The installed SDK says the opposite:

> "The same hot key can, however, be registered by multiple applications... In Mac OS X
> 10.5 and later, you can request exclusive registration for your process only by passing
> `kEventHotKeyExclusive`."
> — `CarbonEvents.h`, `RegisterEventHotKey` discussion

**Revision 1 fabricated a test claim.** It said `tests/test_audio.py` pins the wire format.
`audio.py:44-49` validates sample width only, so a stereo or 44.1 kHz WAV is accepted today.

**Revision 2 contradicted itself twice.** It promised a Tailscale HTTP opt-in while
prohibiting non-loopback HTTP, with no mechanism for the opt-in; and it called an
all-silent buffer "distinct from a denied grant" while the error table filed both under
microphone permission. Both are resolved below.

## Decisions

| Question | Decision |
|---|---|
| Signing | Developer ID, hardened runtime, notarised and stapled. CI produces the artifact |
| Install | `install-client.sh` downloads and verifies a release artifact. It never compiles |
| App shape | `LSUIElement` bundle, menu bar status item, `~/Applications/Hark.app` (no sudo) |
| Capture | Absorbed in-process; the separate `rec` binary goes away |
| Config | `client.json` holds the server URL and the insecure-transport allowlist; the key always lives in `~/.config/hark/key` mode 600 |
| Hotkey | **Undecided.** Phase 0 decides, against the criteria below |
| Migration | Quit Hammerspoon, offer to revoke all three grants, restore or remove the symlink. Delete nothing else |

### Why Developer ID, and what it does not buy

Identical Swift sources produce a different CDHash on every build (measured). Under an
ad-hoc signature that would invalidate the agent's own Accessibility grant on every
rebuild. Revision 1 engineered an installer-side input hash around this; that mechanism is
**deleted**, because CI now produces the binary and the installer never compiles.

Two corrections to how revision 2 stated the benefit:

- TCC binds to the app's **designated requirement**, not simply "Team ID plus bundle ID".
  CI must therefore keep the designated requirement stable across releases and across
  certificate rotation, and Phase 0 must be validated against the **final signed bundle**,
  not an ad-hoc spike binary.
- Notarisation requires the hardened runtime, and microphone capture under the hardened
  runtime requires the audio-input entitlement. `NSMicrophoneUsageDescription` alone is not
  sufficient. The entitlements file is part of the deliverable and CI verifies it.

The client install no longer needs the Xcode command line tools, which removes a
multi-gigabyte dependency from the machine you dictate *from* — the point of #3, #4 and #5.

`~/Applications` keeps the install sudo-free; under Developer ID the path is a packaging
choice, not a permission one.

## Phase 0: the hotkey spike (gates everything else)

Two questions decide the mechanism. Neither should be answered by argument.

1. **Does a keyboard `CGEventTap` require Input Monitoring in addition to Accessibility?**
   `README.md:245-247` states from this project's own experience that an `hs.eventtap`
   watching `flagsChanged` needs it. If that holds for keyDown/keyUp, Carbon is one grant
   and the tap is two, and the permission argument survives revision 1's bad reasoning by a
   different route. If not, the tap is free.
2. **Is `kEventHotKeyReleased` reliable enough for hold-to-talk?**

**Pass/fail criteria**, so the spike produces a decision rather than an impression:

- Test on the oldest supported macOS (13) and the newest available.
- 200 press/release cycles per mechanism; **zero** missed releases required. A missed
  release strands the agent in `recording`, which is why the bar is zero rather than low.
- Include modifier rolls (press ⌃⌥Space, add ⇧ mid-hold, release), sustained CPU load, and
  a display-sleep/wake cycle mid-hold.
- Register the chord while a second app holds it, with and without
  `kEventHotKeyExclusive`, and record whether registration reports the collision.
- Run against the **signed, notarised bundle**, not a bare binary.

If Carbon wins, `kEventHotKeyExclusive` is mandatory — migration cannot claim anything
about chord ownership without it (see Migration).

### The zero-frames question is probably a live bug

Revision 2 framed this as unresolved. It should not be: Apple documents that capture from a
denied device yields silence rather than failure, so `rec.swift:128`'s `framesWritten == 0`
check most likely never fires. That would mean the shipped `rec` never exits 3,
`init.lua:486-496`'s probe always writes `ok`, and `--doctor`'s microphone check is a
confident false PASS today.

Phase 0 validates the replacement implementation rather than deciding whether the premise
holds. If confirmed, file it against the current client — it is a defect in shipped code,
independent of this work.

## Architecture

One SPM package. CI runs `swift build` and `swift test`; the release job assembles, signs,
notarises and staples `Hark.app`.

Bundle ID `com.drycodeworks.hark-agent` — a **new** identifier following the existing
launchd label style, not an existing label. `Info.plist` carries `LSUIElement`,
`NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription` (needed for the
two-machine setup on macOS 15+, and separate from ATS), and the ATS keys below.
Entitlements carry the audio-input entitlement under the hardened runtime.

| File | Responsibility |
|---|---|
| `Config.swift` | Load `client.json`; read and trim the key; enforce the transport policy |
| `Hotkey.swift` | Register the chord (mechanism per Phase 0); press/release; registration failure |
| `Recorder.swift` | AVAudioEngine capture, conversion, in-memory WAV, capture-state reporting |
| `DictateClient.swift` | Bounded POST, decode, typed errors, response sanitisation |
| `AgentController.swift` | State machine, permissions, paste, status heartbeat, logging, menu bar |

Revision 1 had eight files; `Paster`, `Log`, `Diagnostics` and `StatusItem` each had one
caller and no independent policy. The status item shows state and offers Quit only —
`install-client.sh --doctor` is already the diagnostic interface.

### Login start

`SMAppService.mainApp.register()` runs at first launch. Registration only schedules for
*subsequent* logins, so first launch must also start the agent directly. Handle
`.requiresApproval` (macOS has disabled it pending user consent) and `.notFound`/error by
surfacing state in the menu bar and in `--doctor`, rather than assuming success.

### Permissions

Capture permission is never inferred from frame counts:

- `AVCaptureDevice.authorizationStatus(for: .audio)`, and `requestAccess` at first launch
  to raise the dialog. The Microphone pane has no "+" button and lists only apps that have
  already asked, so the request must actually happen.
- Probe at **launch**, not at first hotkey press, so a clean install has a status before
  anyone runs `--doctor`.
- `AXIsProcessTrustedWithOptions` with the prompt option. `AXIsProcessTrusted` alone only
  checks and never prompts, leaving a fresh install with no path to the grant.
- The agent probes local-network reachability itself. A `curl` from `--doctor` is a false
  PASS, because terminal-launched tools are exempt from Local Network privacy.

### Capture

The wire format is **16 kHz, mono, 16-bit signed PCM, little-endian, single `data` chunk** —
stated explicitly here because `audio.py:22` documents it in a comment while enforcing only
sample width.

`/tmp/hark.wav` goes away, and with it the stale-file hazard `init.lua:357` guards against.
`Recorder` builds the 44-byte header itself; RIFF and `data` sizes are back-patched before
the POST, since neither is known until release.

The tap callback runs on an audio thread while key-up runs on the main queue.
`rec.swift:112` mutates `framesWritten` from the callback while `rec.swift:128` reads it
from `stop()` — unsynchronised today, and more consequential in-process. An actor or serial
queue owns the buffer; stop waits for the tap to drain and is idempotent.

## State machine

```
idle ──press──► starting ──first buffer──► recording ──release──► stopping
  ▲                │                            │                    │
  │                └── deadline / failure ──┐    └── cap reached ─────┤
  └──── paste, error, or discard ◄── uploading ◄──── drain complete ──┘
```

| Transition | Behaviour |
|---|---|
| press outside `idle` | ignored |
| `starting`, no first buffer within **5 s** | abort to `idle`, report device or permission |
| `starting` + release | finish starting, then honour the release; never strand |
| engine start fails, or permission denied | abort to `idle` with the specific cause |
| `recording` beyond **120 s** | stop and upload what was captured, with a visible notice |
| `uploading`, request exceeds **30 s** | cancel, return to `idle`, report timeout |
| sleep, or user-session switch | abort capture to `idle` |

`stopping` exists so a press immediately after release cannot start a second capture while
the first drains — revision 1 would have overlapped captures or dropped the utterance.

**One in-flight request**, with a sequence number. The state machine alone mostly prevents
overlap, but a timed-out request that completes late must not paste into a newer capture's
turn, so responses whose sequence is not current are discarded.

A 5 s starting deadline is separate from the 120 s capture cap: today's recorder arms its
ceiling only after the first buffer (`rec.swift:167`), so a device that never delivers one
hangs indefinitely.

## Data flow

1. Press. Ignore unless `idle` and the key resolves.
2. Capture starts; status item and overlay show recording.
3. Release. Tap drains; WAV finalised in memory. **Snapshot the frontmost application.**
4. No frames, or an all-silent buffer: report the capture-side cause and stop. Do not POST.
5. POST with `X-Hark-Key` and `Content-Type: audio/wav`.
6. `200` with empty text: transient "heard nothing", paste nothing. Not an error.
7. `200` with text: sanitise, verify the paste target, set the pasteboard, verify the write,
   then ⌘V.

Never Return. The clipboard is deliberately not restored.

**Paste-target policy.** Transcription is asynchronous, so focus can move between release
and response. If the frontmost application is not the one snapshotted at release, put the
transcript on the pasteboard and report that automatic paste was withheld. Typing a
transcript into whatever happens to be focused later is worse than making the user press
⌘V.

**Paste failure propagates.** If the pasteboard write fails, report it and do **not**
synthesise ⌘V — otherwise the keystroke pastes whatever was on the clipboard before.

## Response handling and limits

The server sanitises at `sanitize.py:23`; revision 1 treated that as sufficient. It is not.
A compromised server, or anyone on the network path of a plaintext two-machine setup,
returns JSON the server's sanitiser never touched, and "Never Return" protects nothing when
the payload itself carries `\r` or `\n` into a terminal without bracketed paste.

| Bound | Value | Applied |
|---|---|---|
| Response body | **1 MiB** | Before JSON decoding, as a streaming byte limit |
| Sanitised text | **8 KiB** (UTF-8 bytes) | After decode and sanitisation |
| Behaviour past either | **Reject, do not truncate** | Rejection is visible; truncation silently corrupts a transcript |

The body cap must bind before decoding — a post-decode cap still lets a hostile server make
`URLSession` buffer an unbounded response.

Sanitisation applies the same rule as `sanitize.py`: C0/C1 controls and Unicode line
separators replaced with a space, whitespace collapsed. The Swift and Python
implementations share test cases, including hostile inputs: embedded newlines, CSI/OSC
sequences, U+2028/U+2029, and an oversized body.

## Transport policy

The two-machine default is plaintext HTTP (`install-client.sh:503`) to what
`README.md:214` calls "a LAN address you trust". On that path an attacker reads the audio,
the transcript and `X-Hark-Key`, and can forge the response the client then types.

Revision 2 prohibited non-loopback HTTP while promising a Tailscale opt-in, with no
mechanism. Resolved:

```json
{
  "server": "http://100.x.y.z:8911/dictate",
  "insecure_transport_hosts": ["100.x.y.z"]
}
```

- HTTPS is required for every non-loopback **hostname**, with no exceptions.
- Plain HTTP is permitted for numeric loopback unconditionally, and for a **numeric IP
  literal** only if that exact address is listed in `insecure_transport_hosts`.
- The allowlist exists because Tailscale already encrypts at the network layer, so HTTP to
  a tailnet IP is a defensible choice — but it must be a stated one, not a silent default.
  Provisioning TLS on the hark server would be a larger change than this issue.
- A Tailscale MagicDNS name is therefore **not** usable over HTTP. Use the tailnet IP.
- `--doctor` reports every entry as a warning naming the assumption it encodes.
- Userinfo (`user@host`) rejected; `install-client.sh:230` already treats it as a defect.
- Redirects cancelled explicitly in the `URLSession` delegate — the default session follows
  them.
- Ephemeral `URLSession`, so credentials and responses are not cached to disk.

**ATS: `NSAllowsLocalNetworking` only, and nothing per-host.** Revision 3 said the
installer would generate per-host `NSExceptionDomains` entries. That is impossible:
`NSExceptionDomains` lives in the signed `Info.plist`, so writing to it after download
invalidates the CDHash and the Developer ID signature, and macOS kills the app at launch.

Restricting insecure HTTP to IP literals is what makes a static plist sufficient —
`NSAllowsLocalNetworking` exempts IP-literal loads without naming any host, so the plist
never has to know which addresses a given user configured. The `Config` allowlist check at
runtime, not ATS, remains the actual boundary. Phase 0 confirms the key behaves this way on
both supported macOS versions, since bare IP handling has changed across releases.

## Configuration

The key always lives at `~/.config/hark/key`, mode 600. Revision 1's inline-versus-file
branch is deleted: one path, one permission contract.

- `install-client.sh` creates `~/.config/hark` mode 700 before writing. On a two-machine
  *client* the directory does not otherwise exist — the server-side `mkdir` ran on the
  other machine.
- The key is read and **trimmed**: `config.py:129` writes `key + "\n"` and
  `install-client.sh:427` strips it today. Raw bytes 401 every request. Embedded whitespace
  is rejected rather than silently trimmed.
- `client.json` is written by a real JSON encoder and replaced atomically. The current
  heredoc (`install-client.sh:541`) validates quotes only in the key (`:468`), so a
  hand-entered URL containing a quote produces an unparseable file.
- `--doctor` stops passing the key in argv (`install-client.sh:291`), where any local
  account can read it from the process table.

**Known residual risk.** Any same-UID process can rewrite `client.json` and point the
trusted agent at an attacker's server; mode 600 does not prevent this. Under Developer ID
the mitigation is available — pin the approved origin in a Keychain item protected by code
identity, requiring in-app confirmation to change. Recorded as a follow-up; it needs its own
design.

## Error handling

| Condition | Message names |
|---|---|
| Connection / transport failure | The URL, and that hark may not be running |
| 401 | Key mismatch, and the file to fix |
| 415 | A client bug, not a microphone problem |
| 400 | Malformed or unsupported audio — a client format bug. Shows the server's `detail` |
| 503 | whisper-server down, `/tmp/hark-whisper.err` |
| Other | Status code and the server's `detail` |
| No frames captured | Device selection, and microphone permission |
| All-silent buffer | Input level or a muted device — **not** reported as a denied grant |

The last two rows resolve revision 2's contradiction. A denied grant is detected by
`authorizationStatus`, never inferred from audio content, so an all-silent buffer means the
device is muted or the level is too low.

**The server must change too.** `app.py:103-107` returns one detail for every
`InvalidAudioError` — "Check that the client has microphone permission and is sending
16 kHz mono 16-bit PCM WAV" — so a malformed header from this client's hand-built WAV would
still send users to Microphone settings. `test_app.py:107` asserts that wording
(`assert "microphone" in detail or "mic" in detail`).

`audio.py` already raises distinct causes: empty body, unreadable WAV, wrong sample width.
Branch on them — empty body keeps the microphone advice, which is right for any client;
malformed or unsupported audio gets format advice. Update the test to match the cause it
exercises.

## Status and `--doctor`

`--doctor` must not run the agent binary itself: a probe launched from the terminal tests
the *terminal's* TCC grant, the trap `install-client.sh:183-190` already documents.

Revision 2's "generation stamp" was not implementable — `--doctor` is bash and cannot read
the agent's internal state. The binding must be independently observable:

```json
{
  "pid": 4321,
  "process_started": "2026-07-31T14:02:11Z",
  "written": "2026-07-31T14:31:02Z",
  "bundle_version": "1.2.0",
  "microphone": "authorized",
  "accessibility": "trusted",
  "local_network": "ok"
}
```

- The agent rewrites this every **30 s** and on every permission change.
- `--doctor` confirms the PID is alive, that `ps -o lstart -p <pid>` matches
  `process_started`, and that `written` is under **90 s** old. Anything else fails.
- No agent running is a FAIL, not a missing check.
- Written atomically, temp file plus rename. Revision 1 would have let `--doctor` read
  partial JSON, and today `install-client.sh:200-204` accepts any existing `ok` line, so a
  stale file survives a revoked grant and reports PASS.

Permissions are re-read after wake and on activation, so revocation during a long-running
agent is reflected rather than cached from launch.

## Release and install contract

"Downloads the artifact" is not a design. The installer replaces code that holds TCC grants,
so:

- **Artifact**: a universal (arm64 + x86_64) `Hark.app`, zipped, attached to a GitHub
  release, with the tag as the version. `install-client.sh` selects the newest release
  unless pinned.
- **Verification, before anything is moved into place**: staple check via `spctl --assess`,
  and `codesign --verify --deep --strict -R` against an expected requirement naming the
  **Team ID and bundle ID**. Notarisation alone only proves *someone* signed it.
- **Replacement**: download to a staging directory, verify, quit any running agent, replace
  atomically, then launch and confirm the status heartbeat appears.
- **Rollback**: keep the previous bundle until the new one reports healthy.
- Failure at any step leaves the existing install untouched.

## Testing

No permissions or microphone needed: config loading, key trimming and rejection,
transport-policy enforcement including the allowlist, the WAV header builder with
back-patched sizes, status-to-error mapping via a stubbed `URLProtocol`, response bounds
(1 MiB body, 8 KiB text, reject-not-truncate), and hostile-response sanitisation.

Server-side, fix the coverage revision 1 wrongly claimed existed: `audio.py` validates
sample width only, so add assertions and server rejection for channel count and sample rate
alongside bit depth, and update the 400-detail test to the branched causes.

CI runs `swift build`, `swift test`, the pytest suite, and verifies the signed bundle's
entitlements and designated requirement.

Not testable in CI, as plainly as the README states its own limits: TCC grants, real hotkey
delivery, real paste into a real window.

## Migration

**Nothing outside hark's own files is deleted.** But "report and move on" is insufficient:

- A running Hammerspoon holds the old Lua **in memory**. Replacing the symlinked file
  changes nothing until it reloads, so both clients bind ⌃⌥Space.
  `install-client.sh:586` already documents that it does not auto-reload.
- Leaving Hammerspoon's grants preserves exactly the privilege escape motivating this
  issue. Any same-UID process can later rewrite the symlink target and reload it.

### Staged cutover

Revisions 2 and 3 contained a deadlock: they required the native agent to be verified
healthy *before* Hammerspoon is quit, while the agent cannot register the hotkey at all
while Hammerspoon owns it — certainly not under `kEventHotKeyExclusive`. Health-checking a
hotkey the old client still holds is not possible, so registration is split out of the
health check and happens after the handover:

1. **Detect a hark-era install.** `~/.hammerspoon/init.lua` is a symlink whose target is a
   `client/init.lua` carrying a hark marker comment — matching the *content*, not this
   checkout's path, so an install still resolves after the repo moves. A real file, or a
   symlink to something without the marker, means the user runs Hammerspoon
   independently: do not quit it, do not offer to revoke anything, and ask before
   proceeding.
2. **Install and health-check the agent with the hotkey disabled.** Everything except
   registration is verified: bundle signature, launch, permissions, status heartbeat,
   server reachability, and key authentication.
3. **Quit Hammerspoon** and wait for process exit. Chord ownership cannot be queried —
   macOS exposes no way to ask WindowServer who owns a hotkey — so confirmed process exit
   is the strongest available signal. Revision 2's "confirms it no longer owns the chord"
   overstated what is possible.
4. **Tell the running agent to register the hotkey**, and verify registration succeeded.
5. **On failure at step 4**: restore the symlink, relaunch Hammerspoon, leave the agent
   installed but inactive, and report what happened. The user ends with a working client
   either way.
6. **Only then** remove the symlink hark created, and offer to revoke **all three** grants —
   `tccutil reset Accessibility`, `Microphone`, and `ListenEvent`, for
   `org.hammerspoon.Hammerspoon`. Input Monitoring is included because `README.md:245-247`
   told Fn-key users to grant it.
7. If the user declines revocation, say plainly that the original exposure remains. The
   install proceeds; it is not silently reported as closed.

Removing `client/rec.swift` while `install-client.sh:404` still compiles it would brick the
installer mid-run, so that ordering holds too.

`client/init.lua` becomes a **silent** no-op stub, for symlinks this installer never sees.

## Blast radius

In scope for the implementation, not follow-ups:

- **`install-client.sh`** — replace the Hammerspoon install, the `swiftc` build
  (`:397-408`), the launch block (`:576-589`), and every `--doctor` check (`:86-110`,
  `:127`, `:173`, `:192`, `:657`, `:720`).
- **`src/hark/app.py`** (`:103-107`) and **`tests/test_app.py`** (`:107`) — branch the 400
  detail by cause.
- **`src/hark/audio.py`** and **`tests/test_audio.py`** — enforce and assert channel count
  and sample rate, not just sample width.
- **`README.md`** — architecture (`:13-14`), install (`:118-135`), `--doctor` (`:155-166`),
  hotkey editing (`:230-247`), two-machine setup, repo layout (`:365-367`).
- **Retire** `client/rec.swift`, `tests/test_client_record.lua`, and
  `client/hark-config.example.lua`, replaced by a `client.json` example.
- **Mark superseded** `docs/superpowers/specs/2026-07-14-hark-open-source-design.md`:
  - `:5` — "(architecture unchanged)", which this design invalidates.
  - `:213-214` — replacing Hammerspoon with a native Swift menubar app listed as a
    non-goal, with the stated reason "It would be the right answer for a *product*; this is
    not one." That deserves an explicit answer, not silent reversal.
  - `:210` — "CI, release automation, versioning, changelogs" listed as a non-goal. #1
    already added CI and this design adds signed release automation.
- Update the status line of `2026-07-14-dictate-design.md` (`:10`).

## Non-goals

- The Fn/🌐 key. Revisit only if Phase 0 selects a tap.
- Pre-warming the audio engine. In-process capture makes it possible; the README's privacy
  trade-off is deliberate and stands.
- Streaming transcription and auto-submit, per the 2026-07-14 spec.
- TLS on the hark server. The `insecure_transport_hosts` allowlist is the interim answer.
- Keychain-pinned server origin. Follow-up, recorded above.

## Open questions

- Phase 0's two answers, which decide the hotkey mechanism.
- Whether the clipboard should self-clear after a timeout when `changeCount` is unchanged.
  Any local process can poll `NSPasteboard` and harvest every transcript without holding
  any TCC grant. Revision 1 documented non-restoration purely as a usability choice; it is
  also a privacy exposure, and the README should say so either way.
