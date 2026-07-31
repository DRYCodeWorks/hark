import logging
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from dictated import app as app_module
from dictated.app import app
from dictated.whisper import WhisperUnavailableError

from conftest import TEST_KEY

FIXTURES = Path(__file__).parent / "fixtures"
WAV = (FIXTURES / "hello.wav").read_bytes()          # real speech, RMS ~4775
SILENCE = (FIXTURES / "silence.wav").read_bytes()    # digital silence, RMS 0

HEADERS = {"content-type": "audio/wav", "x-dictate-key": TEST_KEY}


@pytest.fixture
def stub_transcribe(monkeypatch):
    """Fake whisper's transcribe() so tests don't need a live server."""

    async def fake_transcribe(wav, base_url=None):
        return " Hello, world.\nSecond line. "

    monkeypatch.setattr(app_module, "transcribe", fake_transcribe)


def test_dictate_sanitizes_the_returned_text(stub_transcribe):
    response = TestClient(app).post("/dictate", content=WAV, headers=HEADERS)
    assert response.status_code == 200
    # Newline collapsed - this is the guarantee against premature submit on
    # whatever the client pastes the text into.
    assert response.json() == {"text": "Hello, world. Second line."}


def test_dictate_gates_on_silent_audio_without_ever_calling_whisper(monkeypatch):
    """The real engine does NOT return an empty string on silence - verified
    against the live whisper-server, 1.5s and 6s of digital silence both come
    back as " Thank you.". So `if not text:` was dead code and a mis-tapped
    hotkey would have returned "Thank you." for the client to paste.

    Gate on the audio instead, before transcribing - which also saves a
    pointless whisper round-trip.
    """
    called = []

    async def spy_transcribe(wav, base_url=None):
        called.append(wav)
        return " Thank you.\n"  # what the live engine actually emits

    monkeypatch.setattr(app_module, "transcribe", spy_transcribe)

    response = TestClient(app).post("/dictate", content=SILENCE, headers=HEADERS)

    assert response.status_code == 200
    assert response.json() == {"text": ""}
    assert called == [], "whisper must not be called at all for silent audio"


def test_dictate_returns_thank_you_when_the_audio_has_real_energy(monkeypatch):
    """The guard is an energy gate, NOT a denylist. "Thank you." is a
    perfectly legitimate thing a person might dictate, and it must be
    returned.
    """

    async def thanks(wav, base_url=None):
        return " Thank you.\n"

    monkeypatch.setattr(app_module, "transcribe", thanks)

    response = TestClient(app).post("/dictate", content=WAV, headers=HEADERS)

    assert response.status_code == 200
    assert response.json() == {"text": "Thank you."}


def test_dictate_returns_empty_text_when_transcript_has_no_alphanumerics(
    monkeypatch,
):
    """Low-level noise that clears the energy gate still makes whisper emit
    bare punctuation - the live server returns " .\\n". Nothing was said, so
    the client should paste nothing.
    """

    async def punctuation(wav, base_url=None):
        return " .\n"  # what the live engine actually emits for faint noise

    monkeypatch.setattr(app_module, "transcribe", punctuation)

    response = TestClient(app).post("/dictate", content=WAV, headers=HEADERS)

    assert response.status_code == 200
    assert response.json() == {"text": ""}


def test_dictate_rejects_an_empty_body_naming_the_real_cause(stub_transcribe):
    """A zero-byte WAV is the most likely first-run failure (mis-permissioned
    mic). It used to produce a 503 blaming whisper, sending the user off to
    debug the wrong process entirely.
    """
    response = TestClient(app).post("/dictate", content=b"", headers=HEADERS)

    assert response.status_code == 400
    detail = response.json()["detail"].lower()
    assert "microphone" in detail or "mic" in detail


def test_dictate_rejects_a_body_that_is_not_a_wav(stub_transcribe):
    response = TestClient(app).post(
        "/dictate", content=b"not a wav at all", headers=HEADERS
    )
    assert response.status_code == 400


def test_dictate_returns_503_when_whisper_down(monkeypatch):
    async def down(wav, base_url=None):
        raise WhisperUnavailableError("connection refused")

    monkeypatch.setattr(app_module, "transcribe", down)
    response = TestClient(app).post("/dictate", content=WAV, headers=HEADERS)
    assert response.status_code == 503


def test_health_endpoint():
    assert TestClient(app).get("/health").status_code == 200


# --- auth ------------------------------------------------------------------
#
# POST /dictate was unauthenticated and CSRF-reachable. A page open in a
# browser on ANY tailnet device could
#
#     fetch(url, {method: 'POST', mode: 'no-cors', body: wavBlob})
#
# which is a CORS-*simple* request - no preflight - so the attacker chose the
# WAV and therefore chose the text that landed in the response.
#
# Both X-Dictate-Key and Content-Type: audio/wav are non-safelisted headers
# (only text/plain, multipart/form-data and x-www-form-urlencoded are safelisted
# Content-Type values), so requiring either forces the browser to preflight; no
# CORS middleware is installed, so the preflight fails and the browser blocks
# the request. Requiring both means each independently closes the hole.


def test_dictate_rejects_a_request_with_no_key(stub_transcribe):
    response = TestClient(app).post(
        "/dictate", content=WAV, headers={"content-type": "audio/wav"}
    )
    assert response.status_code == 401


def test_dictate_rejects_a_request_with_the_wrong_key(stub_transcribe):
    response = TestClient(app).post(
        "/dictate",
        content=WAV,
        headers={"content-type": "audio/wav", "x-dictate-key": "not-the-key"},
    )
    assert response.status_code == 401


def test_dictate_rejects_a_wrong_content_type(stub_transcribe):
    """The drive-by CSRF body would arrive as text/plain - a safelisted
    Content-Type that needs no preflight.
    """
    response = TestClient(app).post(
        "/dictate",
        content=WAV,
        headers={"content-type": "text/plain", "x-dictate-key": TEST_KEY},
    )
    assert response.status_code == 415


def test_dictate_rejects_a_missing_content_type(stub_transcribe):
    response = TestClient(app).post(
        "/dictate", content=WAV, headers={"x-dictate-key": TEST_KEY}
    )
    assert response.status_code in (401, 415)


def test_dictate_accepts_content_type_with_parameters(stub_transcribe):
    """`audio/wav; charset=binary` is still audio/wav."""
    response = TestClient(app).post(
        "/dictate",
        content=WAV,
        headers={
            "content-type": "audio/wav; charset=binary",
            "x-dictate-key": TEST_KEY,
        },
    )
    assert response.status_code == 200
    assert response.json() == {"text": "Hello, world. Second line."}


def test_health_needs_no_key():
    """Liveness must stay reachable - launchd and the client both poll it."""
    assert TestClient(app).get("/health").status_code == 200


# --- logging ---------------------------------------------------------------


def test_dictated_logger_actually_emits_info():
    """Under uvicorn's logging config the `dictated` logger had no handler and
    an effective level of WARNING, so the success line was silently dropped.
    """
    assert logging.getLogger("dictated").getEffectiveLevel() <= logging.INFO


def test_success_log_records_length_but_never_the_transcript(stub_transcribe, caplog):
    """The log must identify the size of what was transcribed - and must NOT
    contain the transcript itself. Audio and text never leave this hardware;
    that includes not settling into a world-readable file in /tmp.
    """
    with caplog.at_level(logging.INFO, logger="dictated"):
        response = TestClient(app).post("/dictate", content=WAV, headers=HEADERS)
    assert response.status_code == 200

    logged = "\n".join(r.getMessage() for r in caplog.records)
    assert "26" in logged, "the transcript LENGTH must be recorded"

    transcript = "Hello, world. Second line."
    assert transcript not in logged
    for fragment in ("Hello", "world", "Second line"):
        assert fragment not in logged, f"transcript fragment {fragment!r} was logged"
