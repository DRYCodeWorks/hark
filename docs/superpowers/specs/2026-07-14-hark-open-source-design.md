# hark — packaging `dictate` for public release

**Date:** 2026-07-14
**Status:** IMPLEMENTED 2026-07-31. Kept as the rationale record, not as a plan.
**Supersedes naming in:** `2026-07-14-dictate-design.md` (architecture unchanged)

> **What actually happened, where it differs from this document.**
>
> The plan below assumed the tree would be scrubbed and squashed *before the
> first push*. It wasn't — the repo was pushed with 32 commits of real history
> on 2026-07-28, which is exactly the trap this document warned about. The
> recovery cost more than the prevention would have: a force-push does not
> reliably remove old objects from GitHub (they stay fetchable by SHA until an
> uncontrolled GC), so the remote had to be **deleted and recreated** to
> guarantee the scrub. The lesson stands, sharpened: "clean it up later" is
> not a deferral, it is a change of method.
>
> Everything else shipped as designed — the rename, the config file, the
> loopback default, the plist templates, `install-server.sh`, the optional SSH
> key fetch, and the MIT license.

## Goal

Ship the working tool to **`github.com/DRYCodeWorks/hark`** — **private at first**,
MIT-licensed, and **built to be publishable on day one**.

**Ambition is deliberately bounded: "here's my code", not a product.** No PyPI, no
Homebrew tap, no CI matrix, no support commitment. A stranger should be able to
clone it, run two scripts, and have it work — but nobody is promising them
anything. Every piece of product infrastructure we skip is a tax we don't pay.

### Private first, but scrubbed first

The repo starts **private**, so the author can live with it for a while before
deciding whether it deserves to be public.

**This does not defer any of the de-personalization work, and that is the whole
point.** The trap in "private now, clean it up later" is that once personal
history is pushed, going public stops being a toggle and becomes a history
rewrite on a repo that already has remote commits. So the tree is scrubbed and
the history squashed **before the first push**, private or not.

The success criterion: **making it public is a single settings toggle, requiring
zero cleanup, at any point in the future.** If that isn't true when we finish, we
haven't finished.

The MIT `LICENSE` file ships from day one for the same reason — it costs nothing
now and is one less thing standing between the author and a decision later.

## Rename: `dictate` → `hark`

`dictate` is unsearchable and collides broadly. `hark` is an imperative verb
meaning *listen* — which is what a command name should be — is four letters, and
is uncollided on GitHub (the only near-hits are a Zelda mod and a hashing
library named `murmur`, neither in this space). Renaming now is free; after
anyone installs it, it isn't.

| was | becomes |
|---|---|
| `src/hark/` | `src/hark/` |
| `com.drycodeworks.hark` | `com.drycodeworks.hark` |
| `com.drycodeworks.hark-whisper` | `com.drycodeworks.hark-whisper` |
| `~/.config/hark/key` | `~/.config/hark/key` |
| `~/.hammerspoon/hark-config.lua` | `~/.hammerspoon/hark-config.lua` |
| `/tmp/hark.wav` | `/tmp/hark.wav` |
| `install-client.sh` | `install-client.sh` |
| (none) | `install-server.sh` |

`X-Hark-Key` header becomes `X-Hark-Key`.

## The key insight that makes this cheap

**The two-machine split is already the one-machine story.** The client POSTs to a
URL. Point it at `localhost` and the whole thing collapses onto a single Mac with
*zero* architectural change. We are not adding a mode — we are admitting the
architecture we already have is more general than the setup it was built for.

So: **the default configuration is a single machine, loopback only.** the author's
two-Mac setup becomes one line changed (`bind = "<tailnet-ip>"`), documented as
the advanced case. A stranger never needs to know Tailscale exists.

This also **fixes a security default**. Today `bind` is hardcoded to a tailnet IP.
Shipping that as a default would be actively wrong for someone else; loopback is
the only safe default, and remote binding becomes a deliberate choice the user
makes.

## Configuration

All personal values move to `~/.config/hark/config.toml`, read with stdlib
`tomllib`. Absent file → defaults (which are the single-machine ones).

```toml
[server]
bind = "127.0.0.1"     # loopback. Set to a tailnet IP for the two-machine setup.
port = 8911

[whisper]
host = "127.0.0.1"     # ALWAYS loopback — the ASR server must never be remote-reachable
port = 8910
model = "~/.local/share/whisper-cpp/ggml-large-v3-turbo.bin"
prompt = ""            # vocabulary biasing; see docs. Empty by default.

[audio]
silence_rms_threshold = 150.0
```

**`prompt` defaults to empty.** the author's jargon list (ClickHouse, tmux, Graphite…) is
personal and would be noise for anyone else. It ships as a commented example.

**`silence_rms_threshold = 150.0` is honestly documented as calibrated against
synthetic audio, not a real microphone.** It has not misfired in real use, but a
different mic in a different room may need a different value, and the server logs
the measured rms on every request precisely so a user can calibrate from evidence.

`whisper.host` stays loopback-only in the docs and in the config comments. Making
the ASR server remote-reachable is never correct — audio would leave the machine.

## launchd plists become templates

They currently hardcode `~/...`. They become `.plist.template` files
that `install-server.sh` fills in from the invoking user's paths and the config.

`tests/test_launchd_config_sync.py` — the drift guard that catches a plist whose
`--prompt`/host/port has drifted from the config — **survives and is retargeted**:
it renders the template and asserts the result matches the config. It keeps its
most valuable assertion, that the server is never bound to `0.0.0.0`.

## Install story

```
git clone https://github.com/DRYCodeWorks/hark && cd hark
./install-server.sh        # brew install whisper-cpp; fetch the model; render + load the plists
./install-client.sh        # Hammerspoon + ffmpeg; permissions; hotkey
./install-client.sh --doctor   # diagnose every boundary
```

`install-server.sh` is new (that work was done by hand on the author's server and never
scripted). `install-client.sh` is the existing `setup.sh`, renamed, with the
server-SSH key-fetch made *optional* — on a single machine the key is simply read
from `~/.config/hark/key` locally, with no SSH involved at all.

## README

Written for a stranger, and it **leads with why this exists**: every commercial
dictation tool refuses to paste into a tmux or SSH session — Wispr Flow states
this in its own documentation — because they all synthesize ⌘V into the frontmost
app and that path is fragile there. `hark` pastes at the OS cursor, so the pane
you're looking at is the pane that receives it, remote or not.

It must be honest about:
- the **Hammerspoon dependency** (a real ask; it is what works)
- **what has and hasn't been tested** (one person, one Mac pair, one mic)
- the **silence threshold's synthetic calibration**
- **macOS's two permission traps**, which cost a full debugging session:
  `brew install --cask` installs an app bundle but does not launch it; and the
  Microphone pane has **no "+" button** — it only lists apps that have already
  *requested* access, so mic permission must be **triggered**, never pre-granted.

## Publish the design docs

`docs/superpowers/specs/` ships with the repo (de-personalized, so they are
publishable the moment the repo is). The rationale is the most
interesting artifact here and nobody writes it down: why server-side tmux
injection was wrong (the target heuristic's signal is *inverted* — it tracks
keystrokes, in a tool built to stop you typing), why mosh was wrongly accused,
and why Whisper hallucinates `"Thank you."` at digital silence. They are
de-personalized along with everything else.

## Repo hygiene

- **MIT license.**
- **Squashed history.** The remote starts at one clean commit — done BEFORE the
  first push, private or not, so that going public never requires a rewrite. The 26 existing
  commits contain a tailnet IP, machine names, home paths, and internal
  agent/SDD scaffolding; they are one day old and entirely the author's, so the loss is
  small and the leak is avoided. The local repo keeps its history; those refs are
  simply never pushed.
- `.superpowers/` and any agent scaffolding stay out of the published tree.
- **No secret has ever been committed** (verified); the shared key is generated at
  runtime into `~/.config/hark/key`, mode 600, and is gitignored by living outside
  the repo entirely.

## Migration: this rename breaks the author's working setup, briefly

the author's `hark` is **currently working and in daily use**. The rename touches every
name it depends on, so the cutover must be deliberate rather than incidental:

- The local checkout moves from `.../DRYCodeWorks/dictate` to `.../DRYCodeWorks/hark`.
  The **loaded launchd plists point at the old absolute path** and will fail the
  moment it moves.
- The old services (`com.drycodeworks.hark`, `com.drycodeworks.hark-whisper`)
  must be `bootout`'d, and the new ones (`com.drycodeworks.hark`,
  `com.drycodeworks.hark-whisper`) bootstrapped.
- `~/.config/hark/key` moves to `~/.config/hark/key`. **Move it, don't
  regenerate it** — a fresh key would silently 401 the client until the client
  config is also updated. Moving it keeps the existing client working.
- The client's `~/.hammerspoon/hark-config.lua` → `hark-config.lua`, and
  `init.lua`'s symlink is repointed.
- the author's own values (tailnet bind IP, his jargon `prompt`) move out of the code and
  into his `~/.config/hark/config.toml`. That file is **outside the repo** and is
  never published — which is the entire point.

Implementation must end with **hark working again on the author's machine**, verified by
a real dictation, not merely by a green test suite. A refactor that leaves the
tool broken has failed regardless of what the tests say.

## Non-goals

- PyPI / Homebrew / any package registry.
- CI, release automation, versioning, changelogs.
- Linux or Windows support. This is macOS-only by construction (launchd,
  avfoundation, Hammerspoon, TCC).
- Replacing Hammerspoon with a native Swift menubar app. It would be the right
  answer for a *product*; this is not one.
- Parakeet TDT as the ASR engine (measurably better than Whisper, but a
  dependency and a rewrite — recorded in the original spec as deferred).
