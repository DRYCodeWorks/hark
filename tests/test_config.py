"""The shared secret that gates POST /dictate.

Deliberately not a credential system: one user, one key, one file.
"""

import stat

from dictated import config


def test_env_var_wins(monkeypatch):
    monkeypatch.setenv("DICTATE_KEY", "from-the-env")
    assert config.dictate_key() == "from-the-env"


def test_key_is_generated_and_persisted_when_absent(monkeypatch, tmp_path):
    monkeypatch.delenv("DICTATE_KEY", raising=False)
    key_file = tmp_path / "nested" / "key"
    monkeypatch.setenv("DICTATE_KEY_FILE", str(key_file))

    generated = config.dictate_key()

    assert generated
    assert key_file.exists()
    assert key_file.read_text().strip() == generated
    # Stable across calls - a key that changed per request would lock the
    # client out after the first dictation.
    assert config.dictate_key() == generated


def test_generated_key_is_not_world_readable(monkeypatch, tmp_path):
    monkeypatch.delenv("DICTATE_KEY", raising=False)
    key_file = tmp_path / "key"
    monkeypatch.setenv("DICTATE_KEY_FILE", str(key_file))

    config.dictate_key()

    mode = stat.S_IMODE(key_file.stat().st_mode)
    assert mode == 0o600, f"key file is {oct(mode)}, must be 0600"


def test_generated_key_has_real_entropy(monkeypatch, tmp_path):
    monkeypatch.delenv("DICTATE_KEY", raising=False)
    monkeypatch.setenv("DICTATE_KEY_FILE", str(tmp_path / "key"))

    key = config.dictate_key()

    assert len(key) >= 32


def test_existing_key_file_is_read_not_overwritten(monkeypatch, tmp_path):
    monkeypatch.delenv("DICTATE_KEY", raising=False)
    key_file = tmp_path / "key"
    key_file.write_text("already-here\n")
    monkeypatch.setenv("DICTATE_KEY_FILE", str(key_file))

    assert config.dictate_key() == "already-here"
    assert key_file.read_text() == "already-here\n"
