import httpx
import pytest
import respx

from hark import config
from hark.whisper import transcribe, WhisperUnavailableError

BASE = "http://127.0.0.1:8910"


@respx.mock
async def test_transcribe_returns_text():
    respx.post(f"{BASE}/inference").mock(
        return_value=httpx.Response(200, json={"text": " hello world "})
    )
    assert await transcribe(b"RIFFfake", base_url=BASE) == " hello world "


@respx.mock
async def test_transcribe_posts_wav_as_multipart_file():
    route = respx.post(f"{BASE}/inference").mock(
        return_value=httpx.Response(200, json={"text": "ok"})
    )
    await transcribe(b"RIFFfake", base_url=BASE)

    body = route.calls.last.request.content
    assert b"RIFFfake" in body
    assert b'name="file"' in body


@respx.mock
async def test_transcribe_raises_when_server_down():
    respx.post(f"{BASE}/inference").mock(
        side_effect=httpx.ConnectError("refused")
    )
    with pytest.raises(WhisperUnavailableError):
        await transcribe(b"RIFFfake", base_url=BASE)


@respx.mock
async def test_transcribe_raises_on_http_error():
    respx.post(f"{BASE}/inference").mock(return_value=httpx.Response(500))
    with pytest.raises(WhisperUnavailableError):
        await transcribe(b"RIFFfake", base_url=BASE)


@respx.mock
async def test_transcribe_raises_on_non_json_body():
    respx.post(f"{BASE}/inference").mock(
        return_value=httpx.Response(200, content=b"not json")
    )
    with pytest.raises(WhisperUnavailableError):
        await transcribe(b"RIFFfake", base_url=BASE)


@respx.mock
async def test_transcribe_raises_when_json_missing_text_key():
    respx.post(f"{BASE}/inference").mock(
        return_value=httpx.Response(200, json={"oops": "no text field"})
    )
    with pytest.raises(WhisperUnavailableError):
        await transcribe(b"RIFFfake", base_url=BASE)


@respx.mock
async def test_transcribe_uses_default_base_url_from_config():
    route = respx.post(f"{config.WHISPER_URL}/inference").mock(
        return_value=httpx.Response(200, json={"text": "ok"})
    )
    assert await transcribe(b"RIFFfake") == "ok"
    assert route.called


@respx.mock
async def test_transcribe_raises_when_text_is_null():
    respx.post(f"{BASE}/inference").mock(
        return_value=httpx.Response(200, json={"text": None})
    )
    with pytest.raises(WhisperUnavailableError):
        await transcribe(b"RIFFfake", base_url=BASE)


@respx.mock
async def test_transcribe_empty_string_is_not_an_error():
    respx.post(f"{BASE}/inference").mock(
        return_value=httpx.Response(200, json={"text": ""})
    )
    assert await transcribe(b"RIFFfake", base_url=BASE) == ""
