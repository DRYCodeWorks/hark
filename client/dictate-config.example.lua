-- Template for ~/.hammerspoon/dictate-config.lua.
--
-- client/setup.sh generates the real file for you (fetches `key` from the
-- server over SSH, builds the recorder, chmod 600's the result). This example
-- exists so the expected shape is documented in the repo and so you can
-- hand-write the file if you'd rather not run the script.
--
-- DO NOT commit a copy of this file with a real `key` value filled in.
-- ~/.hammerspoon/dictate-config.lua lives outside this repo entirely, for
-- exactly that reason.

return {
  -- Where dictated is listening. Loopback is the single-machine setup, where
  -- the server runs on this same Mac, and is the default.
  --
  -- For the two-machine setup (this Mac records, another transcribes), use the
  -- transcribing machine's private address instead — a Tailscale/tailnet IP, a
  -- VPN address, or a LAN address you trust. It must match `server.bind` in
  -- that machine's ~/.config/dictate/config.toml.
  server = "http://127.0.0.1:8911/dictate",

  -- The shared secret from the server's ~/.config/dictated/key. Sent as the
  -- X-Dictate-Key header on every request; a wrong or missing value here is
  -- what a 401 response means.
  key = "REPLACE_WITH_THE_SERVER_KEY",

  -- There is NO microphone setting. rec records the system default input, so
  -- pick the mic in System Settings -> Sound -> Input like any other app.
  -- (Earlier versions took an avfoundation device index here. Those indices
  -- are positional and renumber whenever a virtual device comes or goes, so
  -- they were a standing source of "it recorded the wrong thing".)

  -- Optional. Path to the recorder binary that client/setup.sh compiles from
  -- client/rec.swift. Omit it and init.lua uses ~/.hammerspoon/rec.
  recorder = "/Users/you/.hammerspoon/rec",
}
