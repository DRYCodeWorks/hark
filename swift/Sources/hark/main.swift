import AppKit
import Foundation
import HarkCore

// One binary, two roles — the "one Swift app" rewrite of client + server.
//
//   hark serve   → stdlib HTTP server (replaces src/hark/*.py + FastAPI/uvicorn)
//   hark agent   → hotkey, recorder, paste (replaces client/init.lua + rec.swift)
//
// Splitting the roles (rather than always running both in one process) keeps
// the two-machine setup working: the desktop runs `serve`, the laptop runs
// `agent`, one signed binary for both.
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: hark <serve|agent>\n".utf8))
    exit(2)
}

switch args[1] {
case "serve":
    do {
        try HarkServer().serve()
    } catch {
        FileHandle.standardError.write(Data("hark: \(error)\n".utf8))
        exit(1)
    }
case "agent":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // LSUIElement-style: menu bar only
    let controller = AgentController(config: .load())
    controller.start()
    app.run()
default:
    FileHandle.standardError.write(Data("hark: unknown role \(args[1])\n".utf8))
    exit(2)
}
