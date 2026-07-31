--[[
Covers the record lifecycle in client/init.lua.

Run: lua tests/test_client_record.lua

There is no Hammerspoon here - `hs` is stubbed, and the hotkey binding is the
seam: hs.hotkey.bind() hands us the real startRecording/stopRecording.

What is worth pinning down: that a key press launches the recorder with the
arguments rec actually expects, that a release terminates it exactly once,
and that a failure leaves a line in the log. That last one is not decoration
- the log is the only persisted evidence of why a recording failed, and its
absence is what made the original ffmpeg bug take so long to pin down.
]]

local INIT = (arg[0]:match("^(.*)/tests/[^/]+$") or ".") .. "/client/init.lua"

local tasks, logged, deferrals, pressKey, releaseKey, missingPaths

-- Installed for the WHOLE run, not just around the load. logLine() fires from
-- the task callbacks the tests drive, long after loading - restoring io.open
-- any earlier lets this test append its fake stderr to the developer's real
-- ~/.hammerspoon/hark.log, which is the file you would go on to read when
-- diagnosing a genuine failure.
local realDofile, realOpen = dofile, io.open
dofile = function(path)
  if path:match("hark%-config") then
    return { server = "http://127.0.0.1:1/dictate", key = "k" }
  end
  return realDofile(path)
end
io.open = function(path, mode)
  if path:match("hark%.log") then
    return { write = function(_, s) logged[#logged + 1] = s end, close = function() end }
  end
  if path:match("%.wav$") then return nil end
  return realOpen(path, mode)
end

local function buildHs()
  local function task(bin, callback, args)
    local t = { bin = bin, callback = callback, args = args, terminated = 0 }
    t.start = function() t.started = true; return t.startResult ~= false end
    t.terminate = function() t.terminated = t.terminated + 1 end
    tasks[#tasks + 1] = t
    return t
  end

  return {
    alert = { show = function() return 1 end, closeSpecific = function() end },
    -- missingPaths lets a test pretend the compiled recorder is absent.
    fs = {
      attributes = function(path)
        if missingPaths[path] then return nil end
        return { size = 0 }
      end,
    },
    json = { decode = function() return {} end },
    http = { asyncPost = function() end },
    pasteboard = { setContents = function() end },
    eventtap = { keyStroke = function() end },
    sound = { getByName = function() return { play = function() end } end },
    timer = { doAfter = function() deferrals = deferrals + 1 end },
    task = { new = task },
    accessibilityState = function() return true end,
    hotkey = {
      bind = function(_, _, pressed, released) pressKey, releaseKey = pressed, released end,
    },
  }
end

local function load()
  tasks, logged, deferrals = {}, {}, 0
  hs = buildHs()
  assert(loadfile(INIT))()
  tasks = {} -- discard the load-time microphone probe task
end

local function recorder() return tasks[#tasks] end

local failures = 0
local function check(name, fn)
  missingPaths = {}
  local ok, err = pcall(fn)
  if ok then
    print("ok   - " .. name)
  else
    failures = failures + 1
    print("FAIL - " .. name .. "\n       " .. tostring(err))
  end
end

check("a key press starts the recorder with just the output path", function()
  load()
  pressKey()
  assert(#tasks == 1, "expected one recorder, got " .. #tasks)
  assert(recorder().started, "recorder was never started")
  local args = recorder().args
  assert(#args == 1, "rec takes the wav path and nothing else, got " .. #args .. " args")
  assert(args[1]:match("%.wav$"), "expected a wav path, got " .. tostring(args[1]))
end)

check("releasing the key terminates the recorder exactly once", function()
  load()
  pressKey()
  releaseKey()
  assert(recorder().terminated == 1, "terminated " .. recorder().terminated .. " times, want 1")
end)

check("a second press while recording does not start a second recorder", function()
  load()
  pressKey()
  pressKey()
  assert(#tasks == 1, "spurious double key-down started " .. #tasks .. " recorders")
end)

check("releasing with nothing recording is harmless", function()
  load()
  releaseKey() -- no press first
  assert(#tasks == 0, "release started something: " .. #tasks)
end)

check("a clean exit logs nothing", function()
  load()
  pressKey()
  releaseKey()
  recorder().callback(0, "", "")
  assert(#logged == 0, "clean exit wrote to the log: " .. table.concat(logged, " "))
end)

check("a non-zero exit logs the code and rec's stderr", function()
  load()
  pressKey()
  recorder().callback(3, "", "rec: captured no audio - check Microphone")
  local line = table.concat(logged, " ")
  assert(line:match("3"), "exit code missing from log line: " .. line)
  assert(line:match("captured no audio"), "rec's stderr missing from log line: " .. line)
end)

check("a missing recorder binary starts nothing and does not crash", function()
  load()
  missingPaths[os.getenv("HOME") .. "/.hammerspoon/rec"] = true
  pressKey()
  assert(#tasks == 0, "started a recorder that is not installed")
end)

check("the recording is sent immediately, not after a settling delay", function()
  load()
  pressKey()
  releaseKey()
  recorder().callback(0, "", "")
  -- rec finalizes the WAV header before exit(0), so the file is already
  -- complete when this callback runs. A timer here would be 150 ms of pure
  -- latency on every single utterance.
  assert(deferrals == 0, "sending was deferred through hs.timer " .. deferrals .. " time(s)")
end)

os.exit(failures == 0 and 0 or 1)
