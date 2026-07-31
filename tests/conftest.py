import pytest

TEST_KEY = "test-shared-secret"


@pytest.fixture(autouse=True)
def dictate_key(monkeypatch):
    """Pin the shared secret for every test.

    Also keeps the suite from touching the real key file under $HOME: with
    DICTATE_KEY set, config.dictate_key() never falls through to the file.
    """
    monkeypatch.setenv("DICTATE_KEY", TEST_KEY)
    monkeypatch.delenv("DICTATE_KEY_FILE", raising=False)
    return TEST_KEY
