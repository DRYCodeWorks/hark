"""Tests for the energy gate.

Calibration (measured against the live whisper-server on this hardware):

    silence.wav (digital silence)   RMS    0.00  -> whisper: " Thank you.\\n"
    low-level noise                 RMS    9.30  -> whisper: " .\\n"
    `say` speech @ 16 kHz           RMS 3151.94  -> correct transcript
    speech attenuated -26 dB        RMS  157.97  -> correct transcript
    hello.wav (repo fixture)        RMS 4774.99  -> correct transcript

Whisper hallucinates confident-looking text on silence, so "silent transcript
-> inject nothing" is false in practice; the gate has to be on the AUDIO.
"""

import wave
from pathlib import Path

import pytest

from dictated import config
from dictated.audio import InvalidAudioError, rms

FIXTURES = Path(__file__).parent / "fixtures"
SILENCE = (FIXTURES / "silence.wav").read_bytes()
SPEECH = (FIXTURES / "hello.wav").read_bytes()


def test_rms_of_digital_silence_is_zero():
    assert rms(SILENCE) == 0.0


def test_rms_of_real_speech_is_large():
    assert rms(SPEECH) > 1000


def test_silence_is_below_the_threshold_and_speech_is_far_above():
    """The gate only works if the two populations are cleanly separated. If a
    future threshold edit collapses that separation, this fails.
    """
    assert rms(SILENCE) < config.SILENCE_RMS_THRESHOLD
    assert rms(SPEECH) > config.SILENCE_RMS_THRESHOLD
    # Real speech should clear the bar by a wide margin, not squeak past it.
    assert rms(SPEECH) > 10 * config.SILENCE_RMS_THRESHOLD


def test_threshold_sits_above_the_noise_floor_that_hallucinates():
    """Low-level noise (RMS ~9.3) made whisper emit " .". The threshold must be
    comfortably above that noise floor, or the gate lets it through.
    """
    assert config.SILENCE_RMS_THRESHOLD > 50


def test_rms_rejects_empty_bytes():
    with pytest.raises(InvalidAudioError):
        rms(b"")


def test_rms_rejects_bytes_that_are_not_a_wav():
    with pytest.raises(InvalidAudioError):
        rms(b"this is not a RIFF header at all")


def test_rms_rejects_truncated_wav():
    with pytest.raises(InvalidAudioError):
        rms(SPEECH[:20])


def test_rms_rejects_unsupported_sample_width(tmp_path):
    """The threshold is calibrated on the 16-bit scale. An 8-bit WAV would be
    silently mis-scaled, so refuse it loudly instead - the documented contract
    is 16 kHz mono 16-bit PCM.
    """
    path = tmp_path / "eight_bit.wav"
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(1)
        w.setframerate(16000)
        w.writeframes(b"\x80" * 1000)

    with pytest.raises(InvalidAudioError):
        rms(path.read_bytes())


def test_rms_handles_a_wav_with_zero_frames(tmp_path):
    """A header-only WAV must not raise ZeroDivisionError."""
    path = tmp_path / "empty.wav"
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"")

    assert rms(path.read_bytes()) == 0.0
