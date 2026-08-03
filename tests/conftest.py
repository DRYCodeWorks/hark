"""Shared pytest configuration.

The suite is now entirely about the shell installers — the Python server it
used to exercise was replaced by `hark serve` and deleted. Its fixtures
(HARK_KEY, and keeping tests off the real key file) went with it: nothing here
imports hark, and every test that touches $HOME is already given a tmp_path.
"""
