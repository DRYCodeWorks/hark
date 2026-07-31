"""The hark service: audio in, transcript out.

Deliberately contains no business logic - sanitization and ASR each live in
their own module and are imported here by name so tests can fake them. The
The server does not inject the transcript anywhere; it returns it in the HTTP
response and the client pastes it at the cursor. See
docs/superpowers/specs/2026-07-14-dictate-design.md, "REVISED 2026-07-14".
"""

import asyncio
import logging
import secrets
import sys

from fastapi import FastAPI, HTTPException, Request

from hark import config
from hark.audio import InvalidAudioError, rms
from hark.sanitize import sanitize
from hark.whisper import WhisperUnavailableError, transcribe

# Under uvicorn's logging config the `hark` logger has no handler and an
# effective level of WARNING, so every logger.info() below was silently
# dropped - including the success line, the only server-side record that a
# transcription happened. stdout, not stderr, because launchd routes
# StandardOutPath to /tmp/hark.log, which is where that record is
# expected to be found.
logging.basicConfig(
    level=logging.INFO,
    stream=sys.stdout,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)

logger = logging.getLogger("hark")
# Explicit, so the level holds even if something else already configured the
# root logger and made basicConfig() a no-op.
logger.setLevel(logging.INFO)

app = FastAPI(title="hark")

KEY_HEADER = "x-hark-key"
AUDIO_WAV = "audio/wav"

# Silence (energy gate trips, or the transcript has no alphanumeric content)
# is not an error: it means "nothing was said," and the client treats an
# empty string as "paste nothing."
EMPTY_TEXT = {"text": ""}


def _has_alphanumeric(text: str) -> bool:
    return any(ch.isalnum() for ch in text)


def _authorize(request: Request) -> None:
    """Reject anything that isn't our client.

    Both checks matter, and each one independently defeats the drive-by CSRF:
    a page in a browser on any tailnet device could POST a WAV of the
    attacker's choosing - a CORS-*simple* request, so no preflight - and
    thereby choose the text returned in the response. X-Hark-Key and a
    Content-Type of audio/wav are both NON-safelisted (only text/plain,
    multipart/form-data and x-www-form-urlencoded are safelisted Content-Type
    values), so requiring them forces a preflight; no CORS middleware is
    installed, so that preflight fails and the browser blocks the request.
    """
    presented = request.headers.get(KEY_HEADER, "")
    if not secrets.compare_digest(presented, config.hark_key()):
        logger.warning("rejected unauthenticated POST /dictate")
        raise HTTPException(status_code=401, detail="missing or invalid X-Hark-Key")

    # Ignore parameters: `audio/wav; charset=binary` is still audio/wav.
    media_type = request.headers.get("content-type", "").split(";")[0].strip().lower()
    if media_type != AUDIO_WAV:
        logger.warning("rejected POST /dictate with content-type %r", media_type)
        raise HTTPException(
            status_code=415, detail=f"expected Content-Type: {AUDIO_WAV}"
        )


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/dictate")
async def dictate(request: Request) -> dict:
    _authorize(request)

    wav = await request.body()

    # Whisper hallucinates on silence (" Thank you." for digital silence, "."
    # for faint noise), so silence has to be caught on the AUDIO - by the time
    # there is a transcript it is too late to tell "said nothing" from "said
    # thank you". Gating here also skips a pointless whisper round-trip.
    #
    # An empty body used to 503 blaming whisper, when the real cause is a
    # mis-permissioned mic producing a zero-byte WAV.
    try:
        amplitude = await asyncio.to_thread(rms, wav)
    except InvalidAudioError as exc:
        logger.warning("rejected audio: %s", exc)
        raise HTTPException(
            status_code=400,
            detail=(
                f"{exc}. Check that the client has microphone permission and is "
                "sending 16 kHz mono 16-bit PCM WAV."
            ),
        ) from exc

    if amplitude < config.SILENCE_RMS_THRESHOLD:
        logger.info(
            "silent audio (rms %.1f < %.1f); returning empty transcript",
            amplitude,
            config.SILENCE_RMS_THRESHOLD,
        )
        return EMPTY_TEXT

    try:
        raw = await transcribe(wav)
    except WhisperUnavailableError as exc:
        logger.error("whisper-server unavailable: %s", exc)
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    text = sanitize(raw)

    # Audio loud enough to pass the gate can still transcribe to bare
    # punctuation. Nothing was said, so there is nothing to return.
    if not _has_alphanumeric(text):
        logger.info("transcript has no alphanumerics; returning empty transcript")
        return EMPTY_TEXT

    # Log the LENGTH only, never the text - transcripts are private and must
    # never settle into a world-readable file in /tmp.
    #
    # The rms is logged on SUCCESS too, not just when the gate rejects audio.
    # Without it there is no record of how much headroom real speech has above
    # SILENCE_RMS_THRESHOLD, so the day the gate starts eating utterances (a
    # noisier room, a mic further away, a quieter voice) there would be no data
    # to recalibrate from - only a user reporting that dictation "just stopped
    # working sometimes". The threshold was calibrated on synthetic audio, so
    # this is the only real-world evidence there is.
    logger.info(
        "transcribed %d chars (rms %.1f, threshold %.1f)",
        len(text),
        amplitude,
        config.SILENCE_RMS_THRESHOLD,
    )
    return {"text": text}
