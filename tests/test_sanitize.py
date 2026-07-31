from hark.sanitize import sanitize


def test_collapses_newlines_to_spaces():
    assert sanitize("hello\nworld") == "hello world"


def test_collapses_carriage_returns():
    assert sanitize("hello\r\nworld") == "hello world"


def test_collapses_runs_of_whitespace():
    assert sanitize("hello   \n\n  world") == "hello world"


def test_trims_leading_and_trailing_whitespace():
    assert sanitize("  hello world  \n") == "hello world"


def test_preserves_shell_metacharacters_verbatim():
    # These must survive untouched. They are safe because the transcript is
    # passed to tmux on stdin via load-buffer, never interpolated into a
    # command line. Mangling them here would corrupt legitimate dictation.
    raw = 'rm -rf $HOME; echo "hi" && `whoami`'
    assert sanitize(raw) == 'rm -rf $HOME; echo "hi" && `whoami`'


def test_empty_string_returns_empty():
    assert sanitize("") == ""


def test_whitespace_only_returns_empty():
    assert sanitize("  \n\t \r\n ") == ""


def test_strips_ascii_control_characters():
    # A stray ESC in a transcript could otherwise be interpreted as an escape
    # sequence by the receiving application.
    assert sanitize("hello\x1b[31mworld\x00") == "hello [31mworld"


def test_strips_c1_control_characters():
    # C1 controls (0x80-0x9F) are the 8-bit single-byte equivalents of ESC-
    # prefixed C0 sequences: U+009B (CSI) == ESC [, U+009D (OSC) == ESC ],
    # U+0090 (DCS) == ESC P. A speech-to-text engine that emits these must
    # not be able to smuggle escape sequences into the receiving application.
    assert "\x9b" not in sanitize("hello\x9bworld")
    assert "\x9d" not in sanitize("hello\x9dworld")


def test_control_character_between_words_separates_rather_than_fuses():
    # Control-stripping must run as a substitution (control char -> space)
    # before whitespace collapsing, not a deletion, or two words separated
    # only by a control character get silently fused into one.
    assert sanitize("rm\x0c-rf") == "rm -rf"
