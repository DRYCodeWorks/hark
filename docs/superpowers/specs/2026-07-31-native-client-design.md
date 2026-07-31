# Native client design — replacing the Hammerspoon Lua client

Issue: [DRYCodeWorks/hark#2](https://github.com/DRYCodeWorks/hark/issues/2)
Date: 2026-07-31

## Why

`install-client.sh` links `~/.hammerspoon/init.lua` to this repo's `client/init.lua`.
Hammerspoon has exactly one config file, so installing hark claims it.

The permission story matters more than the tidiness one. Accessibility is granted to
Hammerspoon, not to hark. That is a general-purpose scriptable Lua runtime holding a
grant that can observe every keystroke, and its config is a symlink into a git repo, so
`git pull` changes what that grant covers without re-prompting.

What Hammerspoon buys in return, and what this design has to replace, is a **stable
signed TCC identity**. hark currently rides on an already-trusted app by swapping a text
file. Taking that away means hark owns the identity problem itself.

## Decisions

| Question | Decision |
|---|---|
| Signing | Design the bundle and TCC identity now, ship ad-hoc signed, flip to Developer ID later without structural change |
| App shape | `LSUIElement` bundle with a menu bar status item |
| Capture | Absorbed in-process; `rec` as a separate child binary goes away |
| Config | `~/.config/hark/client.json`; on a single-machine install the key is read from `~/.config/hark/key` rather than copied |
| Hotkey | Carbon `RegisterEventHotKey`, with `CGEventTap` documented as the fallback |
| Migration | Nothing on the user's machine is deleted |

### Why RegisterEventHotKey rather than an event tap

`RegisterEventHotKey` registers one chord with the window server and delivers press and
release. It does **not** require Accessibility. Accessibility is still required, but only
to synthesize the ⌘V.

That split is the point. hark asks for permission to *type*, not permission to *watch you
type*. An agent built on `CGEventTap` would need the same all-or-nothing grant that made
the Hammerspoon arrangement uncomfortable in the first place, with a smaller attack
surface but not a smaller permission.

It also makes two failures visible that are currently silent:

- Accessibility missing: the hotkey still registers, so the agent hears the press and
  fails at the paste. It can say "heard ⌃⌥Space, can't paste" instead of nothing.
  `client/init.lua` cannot do this — without Accessibility, `hs.hotkey.bind` never fires
  at all, which the README spends three paragraphs explaining.
- Chord already owned by another app: `RegisterEventHotKey` returns an error.
  `hs.hotkey.bind` returns success and quietly never fires, which is why the README has
  to warn about ⌘⌥Space in prose.

**Risk to verify first:** that `kEventHotKeyReleased` is delivered reliably enough for a
hold-to-talk interaction. This is the first spike, before any other code. If it is not,
fall back to `CGEventTap` and accept the larger grant.

## Measured constraint: rebuilds change the code signature

Identical Swift sources produce a different binary and a different CDHash on every build.
Verified on 2026-07-31 by compiling `client/rec.swift` twice and comparing:

```
build 1: CDHash=5cb20c7342e72829dcb0035fcb19844deb1e6b20
build 2: CDHash=b5aab283cab02415d5fbf9f07ff72259f76c4109
```

`install-client.sh:404` recompiles unconditionally on every run and the script documents
itself as safe to re-run. That is harmless today, because TCC attributes microphone access
to Hammerspoon and `rec`'s own signature is irrelevant. Once the agent **is** the TCC
principal, every re-run invalidates its own Accessibility grant under an ad-hoc signature.

So the installer must skip the build entirely when nothing that affects the binary has
changed. It hashes the **inputs** — every Swift source, `Package.swift`, `Info.plist`, and
`swiftc --version` — stores that hash beside the installed bundle, and rebuilds only on a
mismatch.

The guard has to key on inputs rather than on comparing the built binary against the
installed one, precisely because of the measurement above: identical sources produce a
different binary every time, so an output comparison would always differ and the guard
would never fire.

This is load-bearing, not an optimisation. Under a future Developer ID signature the
constraint disappears, because TCC keys on Team ID plus bundle ID rather than the hash.

## Architecture

One SPM package. `swift build` produces the binary; `install-client.sh` wraps it in
`~/Applications/Hark.app` (no `sudo`); `swift test` runs the unit tests. `Package.swift`
is not an Xcode project, so the "one build command, no project file to maintain" property
survives.

Bundle ID `com.drycodeworks.hark-agent`, matching the existing launchd label convention.
`Info.plist` carries `LSUIElement` and `NSMicrophoneUsageDescription`. Login start uses
`SMAppService.mainApp`, which sets the floor at macOS 13.

| File | Responsibility |
|---|---|
| `Config.swift` | Load `client.json`; resolve the key inline or from `~/.config/hark/key`; validate the URL |
| `Hotkey.swift` | `RegisterEventHotKey` wrapper; press/release callbacks; registration failure |
| `Recorder.swift` | AVAudioEngine, Float32 → 16 kHz mono s16, in-memory WAV, the zero-frames signal |
| `DictateClient.swift` | `URLSession` POST; decode `{"text":…}` / `{"detail":…}`; map status to typed errors |
| `Paster.swift` | `NSPasteboard` set with no restore, then `CGEvent` ⌘V, gated on `AXIsProcessTrusted()` |
| `StatusItem.swift` | Menu bar icon and state; Quit, Reload config, Open log, Run diagnostics |
| `Diagnostics.swift` | Writes the status file that `install-client.sh --doctor` reads |
| `Log.swift` | Append-only log; lengths, never transcript content |

### The WAV never touches disk

`/tmp/hark.wav` goes away, and with it the stale-file hazard that `init.lua:357` guards
against with an `os.remove` before every recording. `AVAudioFile` writes to a URL, so
`Recorder` hand-builds the 44-byte header around the PCM buffer instead. The wire format
is already pinned by `tests/test_audio.py` and unchanged: 16 kHz mono 16-bit PCM.

### The mic-status file stays a file

It is tempting to let `--doctor` run the agent binary with a `--probe` flag. That is wrong
for the reason `install-client.sh:183-190` already documents: a probe launched from the
terminal tests the **terminal's** TCC grant, not the agent's, and produces a confidently
wrong PASS. The agent writes the status; `--doctor` reads it. Only the path changes, to
`~/.config/hark/client-status.json`.

## Data flow

1. ⌃⌥Space down. Return early if already recording, or if no key resolves.
2. Status item to recording, overlay shown, `AVAudioEngine` tap starts.
3. ⌃⌥Space up. Tap stops, WAV bytes returned in memory.
4. Zero frames captured: report the microphone permission cause, log, stop.
5. POST with `X-Hark-Key` and `Content-Type: audio/wav`.
6. `200` with empty text: transient "heard nothing", paste nothing. Not an error — the
   energy gate tripped, or the transcript had no alphanumeric content.
7. `200` with text: set the pasteboard, synthesize ⌘V. Never Return.

The clipboard is deliberately not restored, and auto-submit remains a hard non-goal. Both
carry over unchanged; see the comment above `hs.pasteboard.setContents` in
`client/init.lua` and the Non-goals section of the 2026-07-14 design spec.

## Error handling

The mapping in `init.lua:176-258` carries over as written. It is hard-won and is not being
redesigned:

| Condition | Message names |
|---|---|
| Connection failure | The server URL, and that hark may not be running |
| 401 | The key mismatch, and the config path to fix |
| 415 | A client bug, not a microphone problem |
| 400 | Microphone permission, caught server-side |
| 503 | whisper-server down, `/tmp/hark-whisper.err` |
| Other | The status code and the server's `detail` |

Messages render in a borderless transient overlay rather than Notification Center. A muted
notification is a silent failure, and silent failure is the thing this project repeatedly
designs against.

## Testing

Unit-testable with no permissions and no microphone:

- config loading, key resolution (inline versus `~/.config/hark/key`), URL validation
- the WAV header builder, against `tests/fixtures/hello.wav` and `silence.wav`
- the status-to-error mapping, via a stubbed `URLProtocol`

CI runs `swift build` and `swift test` on the macOS runner added in #1.

Not testable in CI, stated as plainly as the README already states its own limits: TCC
grants, real hotkey delivery, real paste into a real window. Those remain exercised by use.

## Migration

Nothing on the user's machine is deleted.

`client/init.lua` is replaced by a short stub that binds no hotkey and reports that hark
now runs as a native agent. An existing `~/.hammerspoon/init.lua` symlink keeps resolving
and simply does nothing, so the two clients never fight over ⌃⌥Space. The change lands in
this repo rather than in anyone's home directory.

`install-client.sh` reports leftover Hammerspoon-era artifacts (`rec`, `hark-config.lua`,
`.hark-mic-status`, `.hark-mic-probe.wav`) and prints how to revoke Hammerspoon's grants
and remove the cask. It does not do either, because a script cannot revoke a TCC grant.

## Non-goals

- The Fn/🌐 key. It needs an event tap plus Input Monitoring, which is approach B.
- Pre-warming the audio engine. In-process capture makes it possible for the first time,
  but the README's privacy trade-off is deliberate: holding the microphone open lights the
  menu-bar indicator continuously, and that should stay an explicit choice.
- Developer ID signing and notarised releases. Designed for, deferred.
- Streaming transcription and auto-submit, per the 2026-07-14 spec's non-goals.

## Open questions

- Whether `kEventHotKeyReleased` is reliable enough for hold-to-talk. Spike first.
- Whether the ad-hoc rebuild actually invalidates the Accessibility grant in practice on
  current macOS, or merely re-prompts. The rebuild guard is correct either way; this
  determines how loudly the installer has to warn.
- Whether `~/Applications/Hark.app` or `/Applications` is the better home once signing
  arrives and the app might be distributed as a release artifact.
