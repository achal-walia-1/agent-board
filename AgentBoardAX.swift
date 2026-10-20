// Agent Board accessibility helper: watches the Claude desktop app, which has no hooks or local
// chat logs. While Claude is writing a reply the app shows a "Stop" button; this reports that as
// "in progress", and its disappearance as "done". It also opens a chat on request (the board
// writes the chat name to ~/.agent-board/ax-open) by pressing that chat in Claude's sidebar.
//
// Runs as its own LaunchAgent so its one-time Accessibility permission survives board rebuilds.

import AppKit
import ApplicationServices

let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-board")
let eventScript = home.appendingPathComponent("bin/agent-board-event").path
let openRequest = home.appendingPathComponent("ax-open")
let claudeID = "com.anthropic.claudefordesktop"

func attr(_ e: AXUIElement, _ a: String) -> String {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, a as CFString, &v)
    return (v as? String) ?? ""
}

func label(_ e: AXUIElement) -> String {
    [attr(e, "AXTitle"), attr(e, "AXDescription")].first { !$0.isEmpty } ?? ""
}

/// Walk Claude's window and collect its buttons.
func buttons(_ root: AXUIElement) -> [(AXUIElement, String)] {
    var out: [(AXUIElement, String)] = []
    var count = 0
    func walk(_ e: AXUIElement, _ depth: Int) {
        if depth > 60 || count > 5000 { return }
        count += 1
        if attr(e, "AXRole") == "AXButton" {
            let l = label(e)
            if !l.isEmpty { out.append((e, l)) }
        }
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
        for k in (kids as? [AXUIElement]) ?? [] { walk(k, depth + 1) }
    }
    walk(root, 0)
    return out
}

func emit(_ event: String, chat: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [eventScript, "claudeapp", event]
    let pipe = Pipe()
    p.standardInput = pipe
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let payload = (try? JSONSerialization.data(withJSONObject: ["chat": chat])) ?? Data()
    pipe.fileHandleForWriting.write(payload)
    try? pipe.fileHandleForWriting.close()
}

var enabledPid: pid_t = 0
var runningChat: String?

func tick() {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeID).first else {
        if let chat = runningChat { emit("done", chat: chat); runningChat = nil }
        return
    }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    if enabledPid != app.processIdentifier {
        // Electron only exposes its web content to accessibility clients that ask for it.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        enabledPid = app.processIdentifier
    }

    let all = buttons(root)

    // Open a chat the board asked for.
    if let wanted = try? String(contentsOf: openRequest, encoding: .utf8) {
        try? FileManager.default.removeItem(at: openRequest)
        let name = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        app.activate()
        if let hit = all.first(where: { $0.1 == name }) ?? all.first(where: { $0.1.hasPrefix(name) }) {
            AXUIElementPerformAction(hit.0, kAXPressAction as CFString)
        }
    }

    let generating = all.contains { $0.1.lowercased().hasPrefix("stop") }
    let current = all.first { $0.1.hasSuffix(", rename session") }
        .map { String($0.1.dropLast(", rename session".count)) } ?? "Claude chat"

    if generating && runningChat == nil {
        runningChat = current
        emit("start", chat: current)
    } else if !generating, let chat = runningChat {
        runningChat = nil
        emit("done", chat: chat)
    }
}

if !AXIsProcessTrusted() {
    // Shows the system prompt pointing at System Settings > Privacy & Security > Accessibility.
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
}

Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
    if AXIsProcessTrusted() { tick() }
}
RunLoop.main.run()
