"""Audio energy measurement, used to gate silence before it reaches whisper.

Whisper hallucinates on silence. Measured against the live whisper-server on
this hardware: 1.5s and 6s of digital silence both transcribe as " Thank you.",
and low-level noise transcribes as " .". So a transcript-level check for
emptiness is dead code - the engine never emits an empty string - and a
mis-tapped hotkey would return "Thank you." for the client to paste.

The gate therefore has to sit on the AUDIO, before transcription. A denylist of
hallucinated phrases would be wrong: "Thank you." is a perfectly legitimate
thing to dictate. Loudness is the signal that actually distinguishes "the user
said nothing" from "the user said thank you".

Implemented on stdlib `wave` + `array`; `audioop` is removed in Python 3.13
(this runs on 3.13), so the RMS is computed by hand.
"""

import array
import io
import wave

# The documented wire format is 16 kHz mono 16-bit PCM WAV. The threshold in
# config is calibrated on the signed-16-bit scale, so any other sample width
# would be silently mis-scaled against it - refuse it loudly instead.
SUPPORTED_SAMPLE_WIDTH = 2


class InvalidAudioError(Exception):
    """The request body is not a WAV we can measure."""


def rms(wav: bytes) -> float:
    """Return the root-mean-square amplitude of a WAV's PCM samples.

    0.0 for digital silence; roughly 3000-5000 for normal speech.
    """
    if not wav:
        raise InvalidAudioError(
            "empty audio body - the microphone produced no samples"
        )

    try:
        with wave.open(io.BytesIO(wav), "rb") as reader:
            width = reader.getsampwidth()
            if width != SUPPORTED_SAMPLE_WIDTH:
                raise InvalidAudioError(
                    f"expected 16-bit PCM samples, got {width * 8}-bit"
                )
            frames = reader.readframes(reader.getnframes())
    except InvalidAudioError:
        raise
    except (wave.Error, EOFError, OSError, ValueError) as exc:
        raise InvalidAudioError(f"not a readable WAV: {exc}") from exc

    samples = array.array("h")  # signed 16-bit, matching SUPPORTED_SAMPLE_WIDTH
    # Ignore a trailing partial sample rather than raising on an odd byte count.
    usable = len(frames) - (len(frames) % samples.itemsize)
    samples.frombytes(frames[:usable])
    if not samples:
        return 0.0
    if sys_is_big_endian():
        samples.byteswap()  # WAV PCM is little-endian on the wire

    return (sum(s * s for s in samples) / len(samples)) ** 0.5


def sys_is_big_endian() -> bool:
    return array.array("h", b"\x01\x00")[0] != 1
