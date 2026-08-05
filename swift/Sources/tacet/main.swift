import AppKit
import Foundation
import TacetCore

// One binary, two roles — the "one Swift app" rewrite of client + server.
//
//   tacet serve   → stdlib HTTP server (replaces src/tacet/*.py + FastAPI/uvicorn)
//   tacet agent   → hotkey, recorder, paste (replaces client/init.lua + rec.swift)
//   tacet         → agent, because that is what launching the app should do
//
// Splitting the roles (rather than always running both in one process) keeps
// the two-machine setup working: the desktop runs `serve`, the laptop runs
// `agent`, one signed binary for both.
let args = CommandLine.arguments

func writeUsage(to handle: FileHandle) {
    handle.write(Data("""
    usage: tacet [serve|agent]

      serve    run the transcription server (whisper backend, HTTP)
      agent    run the menu-bar dictation agent (hotkey, record, paste)
      --help   this message

    With no arguments tacet runs the agent.

    """.utf8))
}

switch args.count >= 2 ? args[1] : "" {
case "serve":
    do {
        try TacetServer().serve()
    } catch {
        FileHandle.standardError.write(Data("tacet: \(error)\n".utf8))
        exit(1)
    }

// No arguments runs the agent, rather than printing usage and exiting 2.
//
// Double-clicking a .app passes no arguments, and after Quit that is the only
// way back a person would think to try. Exiting 2 there is invisible: Finder
// shows no window, no icon, no error, and nothing is written anywhere the user
// would look. The old behaviour turned "reopen the app" into "know that it is
// a launchd agent and run launchctl kickstart".
//
// `agent` stays spelled out because the launchd plist says it explicitly, and
// a plist that names its role survives someone reading it a year from now.
case "agent", "":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // LSUIElement-style: menu bar only
    let controller = AgentController(config: .load())
    controller.start()
    app.run()

// Usage goes to stdout and exits 0 when it was ASKED for, and to stderr with a
// non-zero exit when it was not. Scripts check one or the other; conflating
// them is how `--help` ends up looking like a failure.
case "--help", "-h", "help":
    writeUsage(to: .standardOutput)
    exit(0)

default:
    FileHandle.standardError.write(Data("tacet: unknown role \(args[1])\n".utf8))
    writeUsage(to: .standardError)
    exit(2)
}
