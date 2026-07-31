--[[
hark — hold-to-talk client for the server's `hark` service.

Hold Ctrl+Alt+Space, speak, release. rec (client/rec.swift, built by
install-client.sh) records the mic to a WAV, the WAV
is POSTed to the server, the transcript comes back in the HTTP response, and
it lands on the clipboard and gets pasted (Cmd+V) into whatever app has
focus - a Claude Code prompt in a remote tmux pane, Slack, a browser,
anything. See docs/superpowers/specs/2026-07-14-dictate-design.md, section
"REVISED 2026-07-14", for why this pastes at the OS cursor instead of the
server injecting into a specific tmux pane: the server cannot know which
pane you're looking at, but macOS always knows what has focus.

This has been exercised end to end - real microphone, real paste target - but
by one person on one pair of Macs. If something misbehaves, the Hammerspoon
console (menu bar icon -> Console) is the first place to look, since Lua
syntax and runtime errors show up there and nowhere else. Note that print()
reaches only that console and is not persisted; anything worth diagnosing
later is appended to ~/.hammerspoon/hark.log instead.
]]

-- ============================================================================
-- Configuration — edit ~/.hammerspoon/hark-config.lua, NOT this file.
-- ============================================================================
--
-- install-client.sh generates that file for you. Its expected shape (see also
-- client/hark-config.example.lua):
--
--   return {
--     server = "http://127.0.0.1:8911/dictate",
--     key = "<the shared secret from the server's ~/.config/hark/key>",
--     recorder = "/Users/you/.hammerspoon/rec",  -- optional; this is the default
--   }
--
-- There is no microphone setting: rec records the system default input.
-- Choose it in System Settings -> Sound -> Input.
--
-- This file is never committed with a real key - it lives outside the repo,
-- in ~/.hammerspoon/, and setup.sh chmod 600's it because it holds a secret
-- in plaintext.

local configPath = os.getenv("HOME") .. "/.hammerspoon/hark-config.lua"
local loadedOk, userConfig = pcall(dofile, configPath)
if not loadedOk or type(userConfig) ~= "table" then
  userConfig = {}
  hs.alert.show(
    "hark: missing or broken " .. configPath .. " — run install-client.sh",
    5
  )
end

-- Loopback default: the single-machine setup, where hark runs on this same
-- Mac. For the two-machine setup, set `server` in hark-config.lua to the
-- transcribing machine's private address.
local SERVER = userConfig.server or "http://127.0.0.1:8911/dictate"
local HARK_KEY = userConfig.key
local WAV_PATH = "/tmp/hark.wav"

-- Deliberately NOT /tmp/hark.wav: a stale probe file must never be
-- mistaken for a real recorded utterance, and vice versa. Lives under
-- ~/.hammerspoon/ (not /tmp) so it doesn't collide with anything else that
-- cleans /tmp; deleted immediately after every probe regardless of outcome.
local MIC_PROBE_PATH = os.getenv("HOME") .. "/.hammerspoon/.hark-mic-probe.wav"

-- Read by install-client.sh's --doctor (and the end of a normal setup.sh run)
-- to learn whether HAMMERSPOON - not the terminal running setup.sh - can
-- reach the microphone. TCC grants are per responsible-app: a probe run
-- from the shell would test the terminal's permission, not Hammerspoon's,
-- and would be worse than useless (a confidently wrong PASS). This file is
-- the only reliable way for setup.sh to learn the real answer.
local MIC_STATUS_PATH = os.getenv("HOME") .. "/.hammerspoon/.hark-mic-status"

-- print() reaches the Hammerspoon console and nowhere else, and that console
-- is not persisted - so a flake that happened an hour ago leaves no evidence
-- anywhere on disk. rec's stderr is the ONLY thing that says why a
-- recording failed, which makes it exactly the thing worth keeping.
local LOG_PATH = os.getenv("HOME") .. "/.hammerspoon/hark.log"

if not HARK_KEY or HARK_KEY == "" then
  hs.alert.show("hark: no key configured in " .. configPath, 5)
end

-- ============================================================================
-- Small helpers
-- ============================================================================

-- Mirrors the server's logging discipline: diagnostics only, never transcript
-- content. rec's stderr names the device or the failure, not speech.
local function logLine(msg)
  print("hark: " .. msg)
  local f = io.open(LOG_PATH, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
    f:close()
  end
end

local function beep()
  -- "Basso" is one of macOS's built-in system alert sounds
  -- (/System/Library/Sounds/Basso.aiff) - chosen because it reads as an
  -- error/failure tone, distinct from routine feedback.
  local sound = hs.sound.getByName("Basso")
  if sound then
    sound:play()
  end
end

-- Best-effort extraction of FastAPI's {"detail": "..."} error body, so the
-- server's own (already-specific) explanation reaches the alert instead of
-- being silently dropped. Falls back to the raw body if it isn't JSON.
local function extractDetail(body)
  if not body or body == "" then
    return "(no response body)"
  end
  local ok, parsed = pcall(hs.json.decode, body)
  if ok and type(parsed) == "table" and type(parsed.detail) == "string" then
    return parsed.detail
  end
  return body
end

-- install-client.sh compiles client/rec.swift to here. userConfig.recorder
-- overrides it, for a build kept somewhere else.
local RECORDER_PATH = os.getenv("HOME") .. "/.hammerspoon/rec"

local function resolveRecorder()
  if userConfig.recorder and hs.fs.attributes(userConfig.recorder) then
    return userConfig.recorder
  end
  if hs.fs.attributes(RECORDER_PATH) then
    return RECORDER_PATH
  end
  return nil
end

-- `mic` selected an avfoundation device INDEX back when ffmpeg did the
-- recording. rec records the system default input instead, which is both
-- steadier (indices renumber when a virtual device like Loom's comes and
-- goes) and the setting people already expect to control this - System
-- Settings -> Sound -> Input. Say so once rather than silently ignoring a
-- key someone deliberately set.
if userConfig.mic then
  print("hark: `mic` in " .. configPath .. " is no longer used - rec records "
    .. "the system default input. Choose it in System Settings -> Sound -> Input.")
end

-- ============================================================================
-- Recording indicator
-- ============================================================================

local recordingAlertId = nil

local function showRecordingIndicator()
  -- 30s ceiling in case something goes wrong and hideRecordingIndicator()
  -- never runs; closeSpecific() below is what normally clears it early.
  recordingAlertId = hs.alert.show("● Recording…", nil, nil, 30)
end

local function hideRecordingIndicator()
  if recordingAlertId then
    hs.alert.closeSpecific(recordingAlertId, 0)
    recordingAlertId = nil
  end
end

-- ============================================================================
-- HTTP response handling
-- ============================================================================
--
-- Every branch below both beeps AND shows an alert naming the likely cause.
-- A silent failure is the worst outcome here - if dictation does nothing,
-- the instinct is to just try again, and a second silent failure reads as
-- "the mic isn't working" when the real cause might be a stale key or a
-- downed tailnet link.

local function handleDictateResponse(status, body)
  -- hs.http reports connection-level failures (host unreachable, DNS
  -- failure, timeout, refused) as a NEGATIVE status with an error message in
  -- `body` - documented behaviour, distinct from a normal HTTP status.
  if status < 0 then
    beep()
    hs.alert.show(
      "hark: can't reach the server (" .. SERVER .. ").\n"
        .. "Check the tailnet is up (tailscale status) and hark is running.\n"
        .. tostring(body),
      6
    )
    return
  end

  if status == 200 then
    local ok, parsed = pcall(hs.json.decode, body or "")
    if not ok or type(parsed) ~= "table" or type(parsed.text) ~= "string" then
      beep()
      hs.alert.show("hark: 200 OK but the response wasn't the expected JSON: " .. tostring(body), 6)
      return
    end

    if parsed.text == "" then
      -- Not an error: silence, or audio that transcribed to no alphanumeric
      -- content. Paste nothing.
      hs.alert.show("heard nothing", 1.5)
      return
    end

    -- Log the LENGTH only, never the transcript itself, mirroring the
    -- server's own logging discipline (src/hark/app.py) - the console is
    -- local, but there's no reason to put speech content in a log at all.
    print("hark: pasting " .. #parsed.text .. " chars")

    -- Deliberately NOT saving/restoring the previous clipboard contents.
    -- Leaving the transcript on the clipboard means a misfired paste (wrong
    -- window focused, paste blocked by the target app, etc.) is recoverable
    -- with a manual Cmd+V instead of having to re-speak the whole utterance.
    -- Do not "fix" this by adding clipboard save/restore.
    hs.pasteboard.setContents(parsed.text)

    -- Synthesize the paste. NEVER follow this with Return/Enter - the user
    -- reviews the transcript before submitting it; auto-submit is a hard
    -- non-goal (see the design spec's "Non-goals" section).
    hs.eventtap.keyStroke({ "cmd" }, "v")
    return
  end

  local detail = extractDetail(body)
  beep()

  if status == 401 then
    hs.alert.show(
      "hark: 401 unauthorized — " .. detail .. "\n"
        .. "Check that the key in " .. configPath .. " matches the server's "
        .. "~/.config/hark/key (re-run install-client.sh to refetch it).",
      7
    )
  elseif status == 415 then
    hs.alert.show(
      "hark: 415 unsupported media type — " .. detail .. "\n"
        .. "This is a client bug (wrong Content-Type header), not a mic problem. "
        .. "Please report it.",
      7
    )
  elseif status == 400 then
    hs.alert.show(
      "hark: 400 bad request — " .. detail .. "\n"
        .. "Almost certainly a microphone permission problem: check System "
        .. "Settings -> Privacy & Security -> Microphone -> Hammerspoon is ON.",
      7
    )
  elseif status == 503 then
    hs.alert.show(
      "hark: 503 — whisper-server is down on the server. " .. detail .. "\n"
        .. "Check /tmp/hark-whisper.err on the server.",
      7
    )
  else
    hs.alert.show("hark: unexpected HTTP " .. tostring(status) .. " — " .. detail, 6)
  end
end

-- ============================================================================
-- Send the recorded WAV
-- ============================================================================

-- rec's last one-line reason for exiting non-zero, so the alert the user
-- actually sees can name the cause instead of pointing at the log. Cleared on
-- every successful capture; see launchRecorder.
local lastRecorderFailure = nil

local function sendRecording()
  if not HARK_KEY or HARK_KEY == "" then
    beep()
    hs.alert.show("hark: no key configured — run install-client.sh or edit " .. configPath, 5)
    return
  end

  local f = io.open(WAV_PATH, "rb")
  if not f then
    beep()
    -- rec deletes the file rather than leave an unusable one, and exits with a
    -- single explanatory line. Show that line: it distinguishes a denied
    -- microphone from a muted one from a dead device, and sending the user to
    -- the log to find out is how a permission failure gets read as a
    -- transcription failure.
    hs.alert.show(
      "hark: nothing was recorded.\n"
        .. (lastRecorderFailure or ("See " .. LOG_PATH .. " for the reason.")),
      8
    )
    return
  end
  local audio = f:read("*a")
  f:close()

  if not audio or #audio == 0 then
    beep()
    -- Not a permission problem: rec settles that with TCC before it opens the
    -- device, and deletes the file rather than leave an empty one. A zero-byte
    -- file here means rec died before finalizing the WAV header.
    hs.alert.show(
      "hark: recorded a zero-byte file - rec exited before finalizing the WAV.\n"
        .. (lastRecorderFailure or ("See " .. LOG_PATH .. " for the reason.")),
      8
    )
    return
  end

  print("hark: sending " .. #audio .. " bytes to " .. SERVER)
  hs.http.asyncPost(SERVER, audio, {
    ["X-Hark-Key"] = HARK_KEY,
    ["Content-Type"] = "audio/wav",
  }, handleDictateResponse)
end

-- ============================================================================
-- Record lifecycle
-- ============================================================================

local recorderTask = nil

-- rec catches SIGTERM, finalizes the WAV and exits 0, so unlike ffmpeg a
-- non-zero exit here means something actually went wrong and its stderr is a
-- single explanatory line rather than a multi-kilobyte banner. That is what
-- makes plain `exitCode ~= 0` the right condition to log on.
local function launchRecorder(recorderPath)
  recorderTask = hs.task.new(recorderPath, function(exitCode, _, stdErr)
    -- Fires once rec has actually exited, which - because it caught the
    -- SIGTERM from :terminate() below and released the AVAudioFile before
    -- exiting - is also the moment the WAV header is final and the file is
    -- safe to read. A stronger guarantee than any fixed sleep would be.
    recorderTask = nil
    lastRecorderFailure = nil
    if exitCode ~= 0 then
      logLine("rec exited " .. tostring(exitCode) .. ": " .. tostring(stdErr))
      -- rec's stderr is one line, already phrased for a human, and prefixed
      -- "rec: " - strip the prefix and hand the rest to sendRecording.
      local reason = tostring(stdErr):gsub("%s+$", ""):gsub("^rec: ", "")
      if reason ~= "" then
        lastRecorderFailure = reason
      end
    end
    hideRecordingIndicator()
    -- Sent immediately, with no settling delay. rec releases the AVAudioFile
    -- (which finalizes the WAV header) and stops the engine BEFORE exit(0),
    -- so by the time this callback runs the file is already complete - the
    -- process-exit callback is the guarantee, and the 150 ms of "belt and
    -- braces" that used to sit here was pure latency on every utterance.
    sendRecording()
  end, { WAV_PATH })

  return recorderTask:start()
end

local function startRecording()
  if recorderTask then
    return -- already recording; guards a spurious double key-down
  end

  if not HARK_KEY or HARK_KEY == "" then
    beep()
    hs.alert.show("hark: no key configured — run install-client.sh or edit " .. configPath, 5)
    return
  end

  local recorderPath = resolveRecorder()
  if not recorderPath then
    beep()
    hs.alert.show(
      "hark: the recorder is not built (looked in " .. RECORDER_PATH .. "). "
        .. "Run install-client.sh.",
      6
    )
    return
  end

  os.remove(WAV_PATH) -- never read a stale WAV from a previous utterance
  showRecordingIndicator()

  if not launchRecorder(recorderPath) then
    recorderTask = nil
    hideRecordingIndicator()
    beep()
    hs.alert.show("hark: the recorder failed to start (" .. recorderPath .. ")", 5)
  end
end

local function stopRecording()
  if not recorderTask then
    return -- key released with nothing recording (e.g. rec already died)
  end
  recorderTask:terminate() -- SIGTERM; rec finalizes the WAV header and exits 0
  -- Do NOT clear recorderTask or hide the indicator here. The completion
  -- callback registered in launchRecorder() does both, exactly when rec
  -- has actually exited - see the comment there.
end

-- ============================================================================
-- Hotkey
-- ============================================================================
--
-- hs.hotkey.bind's real signature (verified against
-- https://www.hammerspoon.org/docs/hs.hotkey.html#bind, not assumed) is:
--
--   hs.hotkey.bind(mods, key, [message,] pressedfn, releasedfn, repeatfn)
--
-- pressedfn fires on key-down, releasedfn on key-up, repeatfn on OS
-- auto-repeat while held - three DISTINCT callback slots, not one callback
-- with a boolean. `message` is an optional string at position 3; omitting
-- it (as here) means position 3 is pressedfn, position 4 is releasedfn.
-- repeatfn is also omitted - trailing Lua arguments can simply be left off -
-- since nothing needs to happen while the key is held beyond what
-- startRecording() already did on the initial press.
--
-- Ctrl+Alt+Space, NOT Option+Cmd+Space: the latter is macOS's built-in
-- Finder search shortcut and the system wins that fight.
hs.hotkey.bind({ "ctrl", "alt" }, "space", startRecording, stopRecording)

-- ============================================================================
-- Startup self-check: Accessibility
-- ============================================================================
--
-- hs.hotkey.bind() above registers the hotkey unconditionally, but without
-- the Accessibility permission Hammerspoon cannot actually capture a global
-- keyboard event - the bind call succeeds either way, and the hotkey then
-- just silently never fires. No error, no console message: holding
-- Ctrl+Alt+Space does literally nothing, which is indistinguishable from
-- several other possible causes (install-client.sh never having launched
-- Hammerspoon at all, a broken config, etc.) unless this is called out
-- explicitly, loudly, right here at load time.
--
-- hs.accessibilityState() with no argument just checks and returns a
-- boolean - it does not itself trigger the system permission prompt.
if not hs.accessibilityState() then
  hs.alert.show(
    "hark: Accessibility is NOT granted to Hammerspoon.\n"
      .. "The hotkey (Ctrl+Alt+Space) CANNOT work until this is fixed.\n"
      .. "System Settings -> Privacy & Security -> Accessibility -> turn ON Hammerspoon.",
    20
  )
end

-- ============================================================================
-- Startup self-check: Microphone
-- ============================================================================
--
-- Unlike Accessibility, macOS's Microphone privacy pane has no "+" button -
-- it only lists apps that have ALREADY REQUESTED microphone access. On a
-- fresh install Hammerspoon has never asked, so it doesn't appear in the
-- list, so there's nothing to toggle. The only way to make macOS show the
-- consent dialog (and make Hammerspoon show up in that list at all) is to
-- actually try to open the mic - which is exactly what this probe does, at
-- load time, instead of waiting for the user's first hotkey press.
--
-- rec runs as Hammerspoon's CHILD process, so TCC attributes the request
-- to Hammerspoon (the responsible app), not to rec or to whatever
-- terminal happens to be running. That attribution is also why this MUST
-- run from inside Hammerspoon and can never be equivalently done by running
-- rec from a shell script - a shell probe would test the terminal's own
-- microphone grant, a different and irrelevant permission.
local function probeMicrophone()
  local recorderPath = resolveRecorder()
  if not recorderPath then
    -- Not a permission problem - the recorder simply isn't built. Leave
    -- MIC_STATUS_PATH untouched (setup.sh's --doctor reports "missing" and
    -- points at this) rather than writing a misleading "denied".
    print("hark: microphone probe skipped - recorder not built at " .. RECORDER_PATH
      .. " (run install-client.sh).")
    return
  end

  os.remove(MIC_PROBE_PATH) -- never inspect a stale probe from an earlier run

  -- status is "ok", "denied", or "error". The third exists because not every
  -- way the probe can fail is a permission problem, and saying "denied" for a
  -- muted device would send the user to a Microphone toggle that is already on.
  local function finish(status, detail)
    os.remove(MIC_PROBE_PATH)

    local statusFile = io.open(MIC_STATUS_PATH, "w")
    if statusFile then
      statusFile:write(status .. "\n" .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
      -- One line, always third: --doctor reads it positionally, and rec's
      -- stderr can carry newlines.
      if detail then
        statusFile:write((detail:gsub("%s+", " ")) .. "\n")
      end
      statusFile:close()
    else
      print("hark: could not write " .. MIC_STATUS_PATH .. " - setup.sh --doctor's mic check will report it as missing.")
    end

    if status == "ok" then
      -- Silent on success - do not nag on every config reload.
      return
    end

    if detail then
      print("hark: microphone probe failed - " .. detail)
    end

    if status == "denied" then
      hs.alert.show(
        "hark: Hammerspoon needs Microphone permission.\n"
          .. "A consent dialog should have appeared just now - click Allow, then\n"
          .. "reload this config (or just try the hotkey again).\n"
          .. "If you missed the dialog or it never appeared: System Settings -> "
          .. "Privacy & Security -> Microphone -> turn ON Hammerspoon.",
        20
      )
    else
      hs.alert.show(
        "hark: the microphone probe failed, but not on permission.\n"
          .. (detail or "no detail") .. "\n"
          .. "Run ./install-client.sh --doctor for the full picture.",
        20
      )
    end
  end

  -- rec asks TCC before it opens the device and reserves exit 3 for the
  -- answer, so the permission question is settled by that one code. It used to
  -- be inferred from an empty capture, which could not work: an ungranted
  -- process still receives buffers, full length and all zeros, so rec exited 0
  -- and this wrote "ok" for a microphone it could not actually hear (issue #9).
  local probeTask = hs.task.new(recorderPath, function(exitCode, _, stdErr)
    if exitCode == 0 then
      finish("ok")
      return
    end
    local reason = "rec exited " .. tostring(exitCode) .. "."
    if stdErr and stdErr ~= "" then
      reason = reason .. " stderr: " .. stdErr
    end
    finish(exitCode == 3 and "denied" or "error", reason)
  end, { MIC_PROBE_PATH, "0.4" })

  if not probeTask:start() then
    finish("error", "rec failed to start (" .. recorderPath .. ").")
  end
end

probeMicrophone()

hs.alert.show("hark loaded", 1.5)
