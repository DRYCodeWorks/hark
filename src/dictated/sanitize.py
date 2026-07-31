"""Transcript sanitization.

Dictation never wants a literal newline. Collapsing them is what makes it
structurally impossible for a transcript to submit a prompt prematurely,
rather than relying on bracketed paste to save us.

Control characters -- C0 (0x00-0x1F, 0x7F) and C1 (0x80-0x9F), which
includes the 8-bit single-byte equivalents of ESC-prefixed sequences like
CSI/OSC/DCS -- are replaced with a space rather than deleted, so a stray
control character can't smuggle an escape sequence into the receiving
application. Substituting instead of deleting also means two words
separated only by a control character become two space-separated words
after whitespace collapsing, not one fused word.
"""

import re

_CONTROL_CHARS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
_WHITESPACE = re.compile(r"\s+")


def sanitize(raw: str) -> str:
    without_control = _CONTROL_CHARS.sub(" ", raw)
    return _WHITESPACE.sub(" ", without_control).strip()
