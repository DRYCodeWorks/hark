# hark

[![CI](https://github.com/DRYCodeWorks/hark/actions/workflows/ci.yml/badge.svg)](https://github.com/DRYCodeWorks/hark/actions/workflows/ci.yml)

![hark — an audio waveform resolving into the word "hark" followed by a terminal cursor](docs/hark-social.png)

Push-to-talk dictation into whatever has focus — most usefully a terminal
session reached over SSH or mosh, but really anywhere: Slack, a browser, any
text field. Hold **Ctrl+Alt+Space**, speak, release; the transcript lands on
the clipboard and is pasted at the cursor.

Transcription is local (whisper.cpp, model held resident). Audio never leaves
your hardware — there is no cloud ASR and no account.

macOS only, by construction: it is built out of launchd, AVAudioEngine, Carbon
hotkeys, and macOS's TCC permission model.

## Why off-the-shelf dictation apps can't do this

Every consumer dictation app (Wispr Flow, superwhisper, VoiceInk, Hex, Handy,
MacWhisper) injects text the same way: clipboard, then synthesize Cmd+V into
the frontmost app. That breaks for a remote terminal session, and Wispr Flow's
own docs say so outright:

> "Direct paste is not supported in WSL terminals, SSH sessions, tmux, or
> screen."

Their workaround is a manual "paste last transcript" hotkey — i.e. not
actually dictation-in-place. A shell or tmux keybinding can't substitute
either: agentic CLIs like Claude Code paint their own input box (there is no
readline buffer for a ZLE widget to hook), and any keybinding evaluated over
SSH runs on the *remote* host, which has no microphone.

`hark` sidesteps this instead of fighting it. Capture and paste happen on
the machine you are physically touching, so the pane you are looking at is
the pane that receives the text. Nothing has to guess a target.

## Architecture

The default is a single Mac: everything below runs on it, bound to loopback,
exposed to nothing.

```
⌃⌥Space held
  └─► rec (AVAudioEngine) records the mic → 16 kHz mono WAV
⌃⌥Space released
  └─► POST /dictate ─────────────►  hark  (HTTP service)
        X-Hark-Key                       │
        Content-Type: audio/wav          ├─► RMS energy gate (silence → "")
                                         ├─► whisper-server (model resident)
                                         └─► sanitize (collapse to one line)
                                    ◄── 200 {"text": "..."}
  ├─► put the text on the clipboard
  └─► synthesize ⌘V into the FOCUSED app
        │
        └─► terminal ──ssh/mosh──► tmux ──► the pane you're actually looking at
```

**Two machines is the same architecture with a different bind address.** If
you want a laptop to record while a desktop holds the model resident, point
the client at the desktop instead of at loopback — see "Two machines" below.
There is no separate mode.

The server does **not** try to guess which terminal pane to inject into, and
does not inject anything itself — it only returns the transcript. The design
spec's "REVISED" section explains why that guess (via `tmux list-clients` and
`client_activity`) turned out to be actively wrong rather than merely fragile:
the only available signal bumps on real keystrokes, so it tracks wherever you
last *typed*, in a tool built to stop you typing.

The clipboard is deliberately **not** restored after pasting: the transcript
stays there, so a misfired paste is recoverable with a manual ⌘V instead of
re-speaking. See the comment above `hs.pasteboard.setContents` in
`client/init.lua` for why this should not be "fixed" later.

## Install

```bash
git clone https://github.com/DRYCodeWorks/hark && cd hark
./install-server.sh     # transcription side
./install-client.sh     # hotkey, mic, paste
```

On one Mac, run both. On two, run `install-server.sh` on the machine that
holds the model and `install-client.sh` on the one you type at.

### 1. Server

`./install-server.sh` installs `whisper-cpp` and `uv` via Homebrew, downloads
a model (~1.5 GB, skipped if present), installs the `hark` package into
`~/.local/share/hark/venv`, generates the shared secret, renders both launchd
plists from your config, loads them, and waits for `/health`. It refuses to
report success if the service never answers.

**The clone is not load-bearing.** launchd runs the copy under
`~/.local/share/hark/venv`, by absolute path and with no `WorkingDirectory`, so
you can move or delete the checkout without breaking the service — and `git
pull` does not live-patch a running daemon. Upgrading is deliberate: pull, then
re-run `./install-server.sh`. The venv is rebuilt from scratch each time, so a
dependency you removed actually goes away.

The model is pinned to a specific upstream revision and verified against a
recorded SHA-256 before it is moved into place — not tracking a mutable
`main`, and not trusting a download that merely completed. To use a different
model, change `MODEL_REVISION` and `MODEL_SHA256` together.

It is safe to re-run, and re-running is how you apply a config change — it
re-renders and reloads.

| Service | Binds to | Logs |
|---|---|---|
| `com.drycodeworks.hark-whisper` | `127.0.0.1:8910` — loopback only, always | `/tmp/hark-whisper.log`, `/tmp/hark-whisper.err` |
| `com.drycodeworks.hark` | `127.0.0.1:8911` by default, never `0.0.0.0` | `/tmp/hark.log`, `/tmp/hark.err` |

`./install-server.sh --doctor` re-runs the checks alone, read-only.

The plists are **rendered by `install-server.sh`**, never edited by hand.
`tests/test_install_server_doctor.py` renders them against a fabricated config
and asserts they agree with it — including that the ASR server is never bound
off loopback.

The server's own plist carries **no address at all**: `hark serve` reads
`~/.config/hark/config.toml` directly, so there is one copy of that fact rather
than two that can disagree. (`uvicorn` needed `--host` baked into the plist,
which is what the old drift guard existed to police.)

A wildcard bind is refused twice: by `install-server.sh` before a plist is
written, and by `hark serve` at startup. The second is the real enforcement;
the first is what turns a launchd crash-loop into a message. Any other address
is accepted, since the two-machine setup binds to a private one on purpose.

The shared secret lives at `~/.config/hark/key` (mode 600), outside the repo.

### 2. Client

```bash
./install-client.sh
```

For a two-machine setup, pass the server's SSH host to skip the prompt:

```bash
./install-client.sh dans-mac-studio
```

It:

1. builds `swift/` into `~/Applications/Hark.app` with SwiftPM and signs it,
2. obtains the shared secret (locally, or over SSH for a two-machine setup),
3. asks you nothing about microphones — `rec` records the system default
   input, chosen in System Settings → Sound → Input,
4. writes `~/.config/hark/client.json` (mode 600 — it holds the secret in
   plaintext),
5. registers `hark agent` as the LaunchAgent `com.drycodeworks.hark-agent`, so
   it starts at login and comes back after a reboot,
6. waits for the agent's own microphone probe, which is what triggers the
   consent dialog,
7. finishes by running the same live checks as `--doctor` and refuses to print
   "setup complete" if any fail.

Safe to re-run at any time; every step checks current state first.

#### Upgrading from the Hammerspoon client

Before 2026-08-03 the client was Hammerspoon plus 505 lines of Lua. That meant
Accessibility — permission to observe every keystroke — was granted to a
general-purpose scriptable runtime whose config was a symlink into this repo,
so a `git pull` changed what the grant covered without re-prompting. The native
agent asks for the same permission with far less behind it.
See [issue #2](https://github.com/DRYCodeWorks/hark/issues/2).

`./install-client.sh` migrates you: `~/.hammerspoon/hark-config.lua` is read
into `~/.config/hark/client.json` and never modified, and Hammerspoon is quit
so the agent can take the hotkey (`Ctrl+Alt+Space` is a system-wide
registration and exactly one process gets it).

Afterwards, clean up by hand — the installer deliberately does not:

```bash
brew uninstall --cask hammerspoon
rm ~/.hammerspoon/init.lua
```

**Revoking Hammerspoon's Accessibility and Microphone grants is the actual
point of the exercise**, and quitting the app does not do it. Switch it off in
System Settings → Privacy & Security.

You will be prompted for both permissions again: TCC keys grants to a code
identity, and the agent is a different one. Until a Developer ID certificate is
in place the bundle is ad-hoc signed, whose designated requirement is a bare
`cdhash` — so **every rebuild is a new identity and the grants must be given
again**. `install-client.sh` detects the change and clears the stale entry for
you, because macOS otherwise leaves the old row in place with its toggle still
switched ON for a binary nothing trusts.

### 3. Configuration

Everything is optional — the defaults are the working single-machine setup.
Copy `config.example.toml` to `~/.config/hark/config.toml` to change the
bind address, the model path, the silence threshold, or the vocabulary prompt.

The **vocabulary prompt** is the cheapest accuracy win available: proper nouns
and jargon that come back mangled usually come back correct once listed in
`whisper.prompt`. It ships empty, because one person's jargon is another
person's noise.

### `./install-client.sh --doctor`

Read-only — changes nothing, exits non-zero if anything is wrong. Run it any
time the hotkey stops working, instead of re-running the whole install:

- `Hark.app` is installed, and its signature verifies
- `~/.config/hark/client.json` exists, is mode 600, has a non-empty key
- the agent is loaded in launchd and actually running
- nothing else is holding `Ctrl+Alt+Space`
- the agent can reach the microphone
- Accessibility is granted
- the server's `/health` is reachable

Each `FAIL` line names its exact fix.

**Every permission check reads what the agent itself reported**, from
`~/.config/hark/status.json` — which the agent rewrites every 30 s, so a stale
file means it died without saying so. Nothing is measured from the outside, and
that is not incidental:

- Running a microphone probe from `--doctor` would test the **terminal's**
  grant, because TCC attributes to the responsible process. A confidently
  wrong PASS.
- Querying `TCC.db` for Accessibility reports what was true for **some earlier
  build**. The row outlives the grant it describes, so after a rebuild it still
  reads granted while the running binary is trusted by nothing. This check did
  exactly that once, printing PASS while the agent was alerting on screen that
  it could not paste.

Only the process can answer for the process. Everything else is a guess that
sometimes agrees.

## Two permissions the installer cannot grant for you

Both need a human click — macOS doesn't allow a script to flip either — and
they fail in different ways. These cost a full debugging session each to
understand, so they are worth reading before you hit them.

1. **Accessibility** — needed to synthesize the ⌘V paste, *not* for the
   hotkey (`RegisterEventHotKey` needs no permission). Without it, recording
   and transcription both succeed and nothing ever appears. The agent checks
   at startup and again at paste time, and if it is missing it says so and
   tells you the transcript is on the clipboard.

2. **Microphone** — `rec` runs as the agent's *child process*, so macOS
   attributes access to **hark**, not to `rec`. This one is **not**
   pre-grantable: the Microphone pane has **no "+" button**, and lists only
   apps that have *already requested* access. hark will not appear there —
   there is nothing to toggle — until something has actually tried to open the
   mic.

   So permission must be **triggered**, never pre-granted. The agent runs a
   short (~0.4s) `rec` probe at startup, which is what fires the consent
   dialog. On success it stays silent and writes `ok`; on failure it alerts,
   writes `denied`, and logs `rec`'s stderr.

   One trap worth knowing if you fork this: under the hardened runtime, a
   missing `com.apple.security.device.audio-input` entitlement makes TCC
   refuse to *prompt at all*. The app then never appears in the pane, and the
   code sees an instant `.denied` indistinguishable from a real refusal.
   Nothing but the unified log names the cause.

Then test for real: put your cursor at a shell prompt, hold **Ctrl+Alt+Space —
all three keys together, not the spacebar alone**, say a short sentence,
release. The sentence should appear at the prompt within a couple of seconds,
**not executed**.

## Two machines

Useful when the Mac you type on can't spare 1.5 GB for a resident model.

On the transcribing machine, set the bind address in
`~/.config/hark/config.toml` to a private address it is reachable at —
a Tailscale/tailnet IP, a VPN address, or a LAN address you trust — then
re-render and reload the plists:

```toml
[server]
bind = "10.x.x.x"     # never 0.0.0.0
```

On the recording machine, point `server` in `~/.config/hark/client.json` at
the same address. `install-client.sh` fetches the key over SSH — pass the
server's SSH host as an argument, or let it prompt.

`whisper.host` stays loopback in both cases and is not configurable. It is the
component that handles raw audio, and audio should not cross a network even a
trusted one.

## Changing the hotkey

Edit `register()` in `swift/Sources/hark/Hotkey.swift`:

```swift
RegisterEventHotKey(
    UInt32(kVK_Space),
    UInt32(controlKey | optionKey),
    ...
```

The key is a `kVK_*` virtual keycode from Carbon's `Events.h`; the modifiers
are `controlKey`, `optionKey`, `cmdKey` and `shiftKey`, OR'd together. Then
re-run `./install-client.sh`.

`RegisterEventHotKey` rather than a `CGEventTap` is a decision with evidence
behind it. A tap reconstructs the chord from the modifier flags carried on each
event, and releasing Ctrl+Alt+Space almost always lifts a modifier at or before
the space bar — so the key-up arrives with the bits already clear. Measured over
45 s of ordinary use: **303 key-downs, 1 key-up**. Carbon delivers pressed and
released as distinct events, does not condition the release on modifier state,
consumes the chord so it does not also reach the focused app, and needs no
permission of its own.

Avoid `cmdKey | optionKey` + space — that's macOS's Finder search shortcut, and
the system wins that fight before `RegisterEventHotKey` sees it.

The Fn/🌐 key needs a different mechanism entirely (a `CGEventTap` watching
`flagsChanged`, the Input Monitoring permission, and disabling the system's own
Fn action). It is **not** a drop-in change to the call above.

## Troubleshooting

**Start here, every time:** `./install-client.sh --doctor`. Most "nothing
happens" reports are one of its checks, not a deeper bug.

0. **Nothing happened, but `--doctor` passes everything.** Check you're
   pressing **Ctrl+Alt+Space — all three keys together**. Then read
   `~/Library/Logs/hark-agent.log`: if it shows `pasting N chars`, the
   transcript reached your clipboard and only the paste failed, which is
   Accessibility.
1. **Recording produces nothing, or the microphone check FAILs.** A microphone
   permission problem almost every time: System Settings → Privacy & Security
   → Microphone → **hark** must be ON. If hark isn't listed at all, it hasn't
   successfully asked yet — see the entitlement note above.
2. **A beep and an alert naming an HTTP status.** The alert names the likely
   cause:
   - **401** — the key in `~/.config/hark/client.json` doesn't match
     `~/.config/hark/key` on the server. Re-run `install-client.sh`.
   - **415** — a client bug in the `Content-Type` header; shouldn't happen
     with an unmodified agent.
   - **400** — the server rejected the audio; usually the same mic-permission
     issue as #1, caught server-side.
   - **503** — `whisper-server` is down. Check `/tmp/hark-whisper.err`.
   - **Negative status / can't reach the server** — connection failure. Check
     the network path and `launchctl list | grep hark`.
3. **The server side looks broken.** `tail -f /tmp/hark.log` and
   `/tmp/hark.err` (server errors, and the length — never the content —
   of each transcript); `/tmp/hark-whisper.err` for ASR crashes.
4. **It "works" but pastes nothing and says "heard nothing."** Not a bug: the
   audio was too quiet to clear the energy gate. Whisper hallucinates
   confident short phrases — famously "Thank you." — on silence, so this is
   filtered on the *audio*, not on the text. Speak louder or closer, check the
   input device, and see `SILENCE_RMS_THRESHOLD` below.

**`/tmp/hark-agent.err` and `~/.config/hark/status.json` are the load-bearing
diagnostics.** The log carries the byte count of each request and the *length* —
never the content — of each transcript; `status.json` carries the live
microphone, Accessibility and hotkey state. A flake an hour old otherwise leaves
no evidence anywhere.

## What's been tested, and what hasn't

One person, two Macs, one microphone. CI runs the pytest suite on Linux and
macOS, shellcheck, and a macOS job that builds `hark.app` and verifies its
signature. What CI cannot reach is everything the permissions model touches — a
real microphone, a real TCC grant, a real paste into a real window. Every bug
found during the agent's first bring-up lived in exactly that gap, and each one
reported success while being broken. Specifically worth knowing:

**The silence threshold is calibrated against synthetic audio, not a real
microphone.** `SILENCE_RMS_THRESHOLD = 150.0` sits ~16× above the noise floor
that produces hallucinated text and ~21× below normal speech, measured with
`say`-generated audio. It has not misfired in real use, but a different mic in
a different room may need a different number. `hark` logs the measured rms
on every request precisely so you can calibrate from evidence instead of
guessing. Aim for ~500+ for headroom.

A related trap: **a call app that "hears you fine" is not proof your mic level
is adequate.** Zoom and Meet apply their own automatic gain; `rec` reads the
raw device with none, so an interface with a hardware gain knob may need it
turned up.

**First-word clipping.** Device-open latency, measured launch to first
captured sample:

| recorder | lead-in |
|---|---|
| `ffmpeg -f avfoundation` | ~1020–1365 ms |
| `rec` (AVAudioEngine) | ~670 ms |

670 ms is still enough to swallow a fast first word if you speak immediately on
key-down. The remaining lever is pre-warming — keeping an audio engine running
and only opening the file on key-down would cut this to near zero, at the cost
of holding the microphone open (and lighting the menu-bar mic indicator)
continuously. Not built: the privacy trade is real and should be a deliberate
choice rather than a default.

**End-to-end latency** has not been measured rigorously. If it feels
consistently above ~2 seconds, the next lever is a faster model (Parakeet TDT
benchmarks better than Whisper on both speed and accuracy), not
micro-optimizing this pipeline.

### Why capture is not ffmpeg

Worth recording, because it cost a full session and the failure looked random.

`ffmpeg -f avfoundation` failed to record roughly half the time, with:

```
[avfoundation @ 0x…] audio format is not supported
```

ffmpeg's avfoundation input accepts only **packed** sample layouts — f32, or
signed 16/24/32-bit. Some interfaces offer exactly one physical layout at every
one of their sample rates: *24-bit signed, unpacked in 4 bytes, high-aligned*.
ffmpeg cannot consume that at all.

It worked half the time because CoreAudio sometimes hands a capture client the
device's **virtual** format (Float32, converted by the HAL) instead of its
physical one, and which you get varies per open. Confirmed by diffing the
CoreAudio unified log across a failing and a succeeding run — the failing one
builds a converter targeting 24-bit unpacked and errors; the succeeding one
stays Float32. Nothing else distinguished them.

Nothing on the ffmpeg side fixes this: the avfoundation demuxer exposes no
audio-format option (every knob it has is video-side), there is no packed
format on the hardware to pin to, and avfoundation is ffmpeg's only macOS input
backend. `AVAudioEngine`'s `inputNode` is Float32 by contract, so
`client/rec.swift` cannot hit this failure mode.

The first fix attempted — retry ffmpeg when it dies early — was wrong. A
relaunch renegotiates the same format. Intermittent is not the same as
transient.

## Repo layout

```
install-server.sh          transcription side: deps, model, plists, services
install-client.sh          builds + installs the agent, plus --doctor
swift/
  Sources/hark/            the agent — hotkey, capture, paste, overlay
  Sources/HarkCore/        config, client, WAV, sanitise, the HTTP server
  Packaging/build-app.sh   assembles and signs Hark.app
  Tests/                   SwiftPM suite (48)
config.example.toml        shape of ~/.config/hark/config.toml
tests/                     pytest suite — drives the installers as subprocesses
.github/workflows/ci.yml   pytest + shellcheck + the signed bundle build
docs/                      design specs
```

Run the suites locally the way CI does:

```bash
uv run --locked pytest -q
shellcheck install-server.sh install-client.sh
cd swift && swift test                 # macOS only
cd swift && bash Packaging/build-app.sh
```

## License

MIT. See [LICENSE](LICENSE).
