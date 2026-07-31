"""Deployment configuration.

The defaults describe the single-machine setup: record, transcribe and paste
all on one Mac, bound to loopback, exposed to nothing. That is the safe default
and the one a new user should get without reading anything.

The two-machine setup — a laptop recording, a desktop transcribing — is the
same architecture with a different bind address. Personal values (a tailnet
bind address, a vocabulary prompt, a calibrated silence threshold) belong in
``~/.config/dictate/config.toml``, which lives outside the repo and is never
published. See ``config.example.toml``.
"""

import os
import secrets
import tomllib
from pathlib import Path

CONFIG_FILE = Path(
    os.environ.get("DICTATE_CONFIG", Path.home() / ".config/dictate/config.toml")
)


def _load(path: Path) -> dict:
    """Parse the TOML config, or return {} when there isn't one.

    A missing file is the ordinary single-machine case, not an error. A
    malformed one is deliberately left to raise: silently falling back to
    defaults could bind the service somewhere the user did not ask for.
    """
    try:
        return tomllib.loads(path.read_text())
    except FileNotFoundError:
        return {}


_cfg = _load(CONFIG_FILE)
_server = _cfg.get("server", {})
_whisper = _cfg.get("whisper", {})
_audio = _cfg.get("audio", {})

# whisper-server: loopback only, and deliberately not configurable. Making the
# ASR server remote-reachable is never correct — it is the one component that
# handles raw audio, and audio must not leave the machine that recorded it.
WHISPER_HOST = "127.0.0.1"
WHISPER_PORT = _whisper.get("port", 8910)
WHISPER_URL = f"http://{WHISPER_HOST}:{WHISPER_PORT}"

# dictated: loopback by default, so the stock install exposes nothing. Set
# server.bind to a private address (e.g. a tailnet IP) for the two-machine
# setup. Never 0.0.0.0 — see the plist drift guard, which enforces this.
DICTATED_HOST = _server.get("bind", "127.0.0.1")
DICTATED_PORT = _server.get("port", 8911)

MODEL_PATH = Path(
    _whisper.get("model", "~/.local/share/whisper-cpp/ggml-large-v3-turbo.bin")
).expanduser()

# Vocabulary biasing. whisper-server's --prompt seeds the decoder, which is the
# cheapest accuracy win available and gates whether an LLM cleanup pass is ever
# needed. Empty by default — one person's jargon is another person's noise.
# Set whisper.prompt to your own terms and extend it as words show up mangled.
VOCAB_PROMPT = _whisper.get("prompt", "")

TRANSCRIBE_TIMEOUT_S = 60.0
CONNECT_TIMEOUT_S = 5.0

# Below this RMS amplitude (signed-16-bit scale) the audio is treated as
# silence and never reaches whisper.
#
# Whisper hallucinates confident text on silence, so the transcript cannot be
# trusted to reveal that nothing was said. Measured against a live
# whisper-server:
#
#   digital silence          RMS    0.00  -> " Thank you."   <- would be returned
#   low-level noise          RMS    9.30  -> " ."
#   speech, -32 dB           RMS   79.17  -> correct transcript
#   speech, -26 dB           RMS  157.97  -> correct transcript
#   `say` speech @ 16 kHz    RMS 3151.94  -> correct transcript
#   tests/fixtures/hello.wav RMS 4774.99  -> correct transcript
#
# 150 sits ~16x above the noise floor that hallucinates and ~21x below normal
# speech. A false reject is visible (the response says {"text": ""}) and costs
# one repeated utterance; a false accept silently returns "Thank you." for the
# client to paste.
#
# Honest caveat: this was calibrated against synthetic `say` audio, not a real
# microphone. If your mic has a higher noise floor, raise it — the separation
# is three orders of magnitude, so there is room. The server logs the measured
# rms on every request precisely so you can calibrate from evidence.
SILENCE_RMS_THRESHOLD = _audio.get("silence_rms_threshold", 150.0)

# The shared secret gating POST /dictate, sent by the client as X-Dictate-Key.
#
# Without it the endpoint was CSRF-reachable: a page open in a browser on any
# machine that can route to this one could POST a WAV of the attacker's choosing
# (a CORS-simple request needs no preflight) and thereby choose the text typed
# into a live agent's terminal. X-Dictate-Key is a non-safelisted header, so
# requiring it forces a preflight, which fails - no CORS middleware is installed.
#
# Deliberately not a credential system: one user, one key, one file. The key is
# generated on first use and persisted, so the client can be configured once by
# reading the file. It lives outside the repo and is never committed.
KEY_FILE = Path.home() / ".config/dictated/key"


def _key_file() -> Path:
    return Path(os.environ.get("DICTATE_KEY_FILE", KEY_FILE))


def dictate_key() -> str:
    """Return the shared secret, generating and persisting one if needed."""
    from_env = os.environ.get("DICTATE_KEY")
    if from_env:
        return from_env

    path = _key_file()
    try:
        return path.read_text().strip()
    except FileNotFoundError:
        pass

    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = secrets.token_urlsafe(32)
    try:
        # Exclusive create: if a concurrent request won the race, use its key
        # rather than overwriting it and locking that request's client out.
        with path.open("x") as f:
            f.write(key + "\n")
        path.chmod(0o600)
    except FileExistsError:
        return path.read_text().strip()
    return key
