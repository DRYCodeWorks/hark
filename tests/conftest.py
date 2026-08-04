"""Shared pytest configuration.

The suite is now entirely about the shell installers — the Python server it
used to exercise was replaced by `tacet serve` and deleted. Its fixtures
(TACET_KEY, and keeping tests off the real key file) went with it: nothing here
imports tacet, and every test that touches $HOME is already given a tmp_path.
"""
