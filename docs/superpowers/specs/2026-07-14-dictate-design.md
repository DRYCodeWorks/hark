> **Historical document.** Written 2026-07-14, before the tool was renamed
> to `tacet`. It says `dictate` and `dictated` throughout, and its first half
> describes a server-side tmux-injection design that was abandoned — see the
> "REVISED" section for why. Kept as the rationale record; the shipped naming
> is in the README.

# dictate — local push-to-talk dictation into a remote tmux pane

**Date:** 2026-07-14
**Status:** Design approved, pending implementation plan

## Problem

Wispr-Flow-style dictation — hold a key, speak, have the text land in the prompt
you're typing into — but with two hard constraints:

1. **Audio never leaves hardware the author controls.** No cloud ASR.
2. **The target is a Claude Code prompt inside a tmux session on the server machine,
   reached from a laptop over mosh.**

Constraint 2 is the hard one, and it is why no off-the-shelf product solves this.

## Why the obvious answers don't work

**Off-the-shelf dictation apps cannot hit this target.** Every one of them
(Wispr Flow, superwhisper, VoiceInk, Hex, Handy, MacWhisper) injects text the
same way: put it on the clipboard, synthesize ⌘V into the frontmost macOS app.
Wispr Flow's own documentation states the consequence plainly:

> "Direct paste is not supported in WSL terminals, SSH sessions, tmux, or screen."

Their workaround is a manual "paste last transcript" hotkey — i.e. not the
feature. Ghostty compounds this: `TERM=xterm-ghostty` takes a kitty-protocol path
that mangles multi-line paste ([claude-code#54700]).

**A shell/tmux keybinding cannot work either.** A zsh ZLE widget never fires
inside a TUI (Claude Code paints its own input box, it is not a readline buffer),
and over SSH it would execute on the *remote* host, which has no microphone.

**Mosh is *not* the problem.** It has supported bracketed paste (DECSET 2004)
since 2013 ([mosh#427]) and passes the bracket bytes through verbatim. This was
investigated and cleared; it is recorded here so it isn't re-litigated.

**LM server cannot do the ASR.** Its OpenAI-compatible server exposes only
`/v1/models`, `/v1/responses`, `/v1/chat/completions`, `/v1/embeddings`,
`/v1/completions`. There is no `/v1/audio/transcriptions`; the [feature request]
is still open, and `lmserver.ai/transcribe` is an unshipped "coming soon" page.
LM server remains a *candidate for the optional cleanup pass* (see Deferred).

## REVISED 2026-07-14 — the server does NOT inject; it returns the transcript

The original design had the server inject directly into the tmux pane's pty, on
the reasoning that the transcript is *produced* on the server so there is no need
to ship it back. **That was wrong, and it was wrong for an interesting reason.**

Injecting on the server means the server must decide **which pane the author is looking
at** — and it cannot know. `resolve_target()` guessed via "most recently active
tmux client," and a live measurement showed that signal is *inverted*:
`client_activity` bumps on **real keystrokes only** — not on output, not on
injected text, and **not on dictating**. So the rule reduces to "wherever the author last
physically typed," in a tool whose entire purpose is to let him stop typing. The
failure is **sticky, not transient**: type `y` into session 18, walk to session 1,
dictate — it goes to 18, and keeps going to 18 forever. With three tmux clients
attached (two of them other live Claude Code agents), that is not a corner case.

**Sending the transcript back to the laptop and pasting it at the cursor deletes
the problem rather than mitigating it.** There is nothing to guess: the cursor is
already where the author is looking. macOS knows what app has focus, mosh forwards the
bytes, tmux delivers them to the pane he is actually in. **Human attention is the
targeting signal**, and it is free and always correct.

The two objections that originally killed this approach have both since died:

- **Mosh mangling bracketed paste** — investigated and false. Mosh has supported
  DECSET 2004 since 2013 ([mosh#427]) and passes the bracket bytes verbatim.
- **Ghostty's multi-line paste bug** ([claude-code#54700]) — real, but it is a
  *multi-line* bug, and `sanitize()` guarantees every transcript is a single line.
  It cannot fire.

Cost: an Accessibility grant on the laptop. Benefit: correct targeting always,
plus system-wide dictation (Slack, browser) for free.

**Consequence:** `tmux.py` and `resolve_target()` are deleted. They are not merely
unused — they carry the broken heuristic, and keeping reachable code with a known
misdelivery bug is a liability. Git retains them if ever needed.

The server is still a free dependency: the author is *already* mosh'd into it, and it
holds the model resident, which is the point of putting ASR there on an 8 GB
laptop.

## Architecture

```
laptop (8 GB)                     server machine (M4 Max, 64 GB)
──────────────────                     ─────────────────────────
⌃⌥Space held
  └─► ffmpeg records mic → 16 kHz mono WAV
⌃⌥Space released
  └─► POST /dictate ──[tailnet]──►  dictated  (HTTP service)
        X-Tacet-Key                    │
        Content-Type: audio/wav          ├─► RMS energy gate (silence → "")
                                         ├─► whisper-server (model resident)
                                         └─► sanitize (collapse to one line)
                                    ◄── 200 {"text": "..."}
  ├─► put text on the clipboard
  └─► synthesize ⌘V into the FOCUSED app
        │
        └─► Ghostty ──mosh──► tmux ──► the pane the author is actually looking at
                                        (Claude Code's prompt, a shell, anything)
```

The clipboard is deliberately **not** restored afterward: the transcript stays
there, so a misfired paste is recoverable with ⌘V instead of re-speaking.

### Components

| Component | Host | Responsibility |
|---|---|---|
| `dictate-client` | laptop | Hold-to-talk hotkey, mic capture, POST, user feedback |
| `dictated` | server | Receive audio → transcribe → sanitize → inject into tmux |
| `whisper-server` | server | ASR. Already installed (whisper-cpp 1.8.4), model on disk |

Each is independently testable and replaceable. `dictate-client` knows only the
`/dictate` endpoint. `dictated` knows only "audio in, text into a pane."

### `dictate-client` (laptop)

**Implementation: Hammerspoon (Lua, ~40 lines) driving `ffmpeg` as a subprocess.**

Hammerspoon is chosen for the *hotkey*, because it covers both phases: `hs.hotkey`
handles the ⌃⌥Space combo now, and `hs.eventtap` watching `flagsChanged` handles
the Fn key later — one tool, no rewrite. Costs an Accessibility grant.

**Hammerspoon cannot record audio.** `hs.audiodevice` manages devices; it has no
capture API. Recording is therefore done by spawning `ffmpeg` via `hs.task`:

- Key down → `hs.task` spawns `ffmpeg -f avfoundation -i :<mic> -ar 16000 -ac 1`
  writing a temp WAV. 16 kHz mono is whisper's native rate — no server-side resample.
- Key up → terminate ffmpeg, POST the WAV, delete it.
- Requires `ffmpeg` on the laptop (Homebrew).
- Non-blocking throughout: `hs.task` is async; a slow round-trip must never freeze
  the UI or block the next utterance.

**This subprocess spawn is the source of the first-word-clipping risk.** ffmpeg
takes ~100–300 ms to open the input device, during which audio is lost. The
mitigation — a pre-warmed audio engine that is always running and merely starts
*retaining* buffers on key-down — requires a small Swift recorder instead. It is
deliberately **not** pre-built: v1 measures whether clipping is actually
perceptible before paying for it.

### `dictated` (server)

Single endpoint: `POST /dictate`, body = `audio/wav`.

1. Write audio to a temp file.
2. Transcribe via `whisper-server` (HTTP, model already resident).
3. **Sanitize:** collapse all newlines and runs of whitespace to single spaces;
   trim. Dictation never wants a literal newline, and this makes premature-submit
   structurally impossible rather than a setting to remember.
4. Resolve target pane (below).
5. Inject: `tmux load-buffer -` (transcript on **stdin**) then
   `tmux paste-buffer -p -t <pane>`.
6. Return `200 {"text": ...}`.

### Injection: why `load-buffer` + `paste-buffer -p`, not `send-keys`

- **`load-buffer -` reads from stdin**, so the transcript is never interpolated
  into a command line. Quotes, semicolons, backslashes in a transcript cannot
  escape into shell or tmux command context. `send-keys` would require quoting
  the transcript, which is a bug waiting to happen.
- **`-p` applies bracketed paste** if the target application requested it, so
  Claude Code receives a genuine paste rather than synthetic keystrokes.
- We sanitize newlines *anyway*. Belt and braces; the cost is zero.

### Target pane resolution

The active pane of the **most recently active attached tmux client**. Derived from
`tmux list-clients` (ordering by `#{client_activity}`) → that client's session →
its current window's active pane.

If no client is attached: return `409`, inject nothing, client beeps. Injecting
into a detached session would put text somewhere the author cannot see.

### Accuracy: vocabulary biasing

Seed whisper's `--prompt` with the actual working vocabulary — ClickHouse, tmux,
Graphite, Terraform, Kubernetes, Alembic, MergeTree, Tailscale. This is the
cheapest available accuracy win and it is what decides whether a downstream LLM
cleanup pass is ever needed.

### Model choice

**v1 uses whisper `large-v3-turbo` via `whisper-server`** — zero new installation;
both are already present on the server.

Recorded for later: **Parakeet TDT beats Whisper on English on both axes** —
6.05% vs 7.44% avg WER ([Open ASR Leaderboard]) and substantially faster. On the
*server* side the ANE path (FluidAudio) is a Swift library with no HTTP server, so
adopting Parakeet means `parakeet-mlx` + a FastAPI wrapper. Deferred until v1's
measured accuracy justifies it.

### Security / transport

- `dictated` binds to the **tailnet interface only**, never `0.0.0.0`.
- Audio and transcripts stay on the author's tailnet, on the author's hardware.
- `whisper-server` binds to loopback on the server.

### Error handling

| Condition | Behaviour |
|---|---|
| No tmux client attached | `409`; nothing injected; client beeps |
| Empty / silent transcript | No-op; nothing injected |
| server unreachable | Client notification |
| whisper-server down | `503`; client beeps |

### Testing

- **`dictated` is the real test seam:** POST a fixture WAV, assert the transcript
  and assert the injection command. Sanitization gets direct unit tests, including
  transcripts containing newlines, quotes, and semicolons.
- **Hotkey + mic capture are verified by hand.** They cannot be meaningfully faked,
  and pretending otherwise would produce tests that pass while the feature is broken.

## To measure in v1 (not guess)

1. **First-word clipping** from recorder startup latency. If real, the fix is a
   pre-warmed Swift audio engine instead of Hammerspoon's recorder — deliberately
   not pre-built.
2. **End-to-end latency**: keypress → text visible in the pane.
3. **Jargon accuracy** with `--prompt` biasing, which gates the cleanup pass below.

## Deferred (YAGNI until measured)

- **LLM cleanup pass.** Route the transcript through a local LLM (LM server on the
  server, 64 GB) to fix technical vocabulary. Only if `--prompt` biasing proves
  insufficient. Adds latency and a second resident service.
- **Fn / 🌐 key.** Step 2. Needs a CGEvent tap on `maskSecondaryFn`, Input
  Monitoring permission, *System Settings → Keyboard → "Press 🌐 key to: Do
  Nothing"*, and debouncing. Isolated to `dictate-client`; deliberately sequenced
  after the pipeline is proven so a broken Fn cannot be confused for a broken
  pipeline.
- **System-wide dictation** (Slack, browser). Would require the clipboard + ⌘V
  path, with all its hazards. Additive — a second hotkey, no conflict with this.
- **Parakeet TDT** as the ASR engine.

## Non-goals

- Real-time / streaming transcription. Utterance-at-a-time is the interaction.
- Auto-submit (pressing Enter after injection). the author reviews before sending.
- Any target outside a tmux pane on the server.

[claude-code#54700]: https://github.com/anthropics/claude-code/issues/54700
[mosh#427]: https://github.com/mobile-shell/mosh/issues/427
[feature request]: https://github.com/lmserver-ai/lmserver-bug-tracker/issues/1715
[Open ASR Leaderboard]: https://arxiv.org/html/2510.06961v1
