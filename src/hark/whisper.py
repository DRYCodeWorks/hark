"""HTTP client for whisper.cpp's whisper-server.

The server holds the model resident; a fresh `whisper-cli` per utterance would
reload 1.5 GB every time. Vocabulary biasing is applied at server startup via
--prompt (see launchd/), not per request.
"""

import httpx

from hark import config


class WhisperUnavailableError(Exception):
    """whisper-server did not answer, or answered with an error."""


async def transcribe(wav: bytes, base_url: str = config.WHISPER_URL) -> str:
    files = {"file": ("audio.wav", wav, "audio/wav")}
    data = {"response_format": "json", "temperature": "0.0"}
    timeout = httpx.Timeout(
        config.TRANSCRIBE_TIMEOUT_S, connect=config.CONNECT_TIMEOUT_S
    )
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            response = await client.post(
                f"{base_url}/inference", files=files, data=data
            )
            response.raise_for_status()
            text = response.json()["text"]
            if not isinstance(text, str):
                raise ValueError(f"expected str for 'text', got {text!r}")
            return text
    except httpx.HTTPError as exc:
        raise WhisperUnavailableError(str(exc)) from exc
    except (ValueError, KeyError) as exc:
        raise WhisperUnavailableError(
            f"malformed response from whisper-server: {exc}"
        ) from exc
