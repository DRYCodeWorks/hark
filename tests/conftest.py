import pytest

TEST_KEY = "test-shared-secret"


@pytest.fixture(autouse=True)
def hark_key(monkeypatch):
    """Pin the shared secret for every test.

    Also keeps the suite from touching the real key file under $HOME: with
    HARK_KEY set, config.hark_key() never falls through to the file.
    """
    monkeypatch.setenv("HARK_KEY", TEST_KEY)
    monkeypatch.delenv("HARK_KEY_FILE", raising=False)
    return TEST_KEY
