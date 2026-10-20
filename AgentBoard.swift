// Agent Board: a floating widget that tracks Claude Code, Cursor and Codex tasks.
// A Doberman mascot shows the mood: typing hard while agents cook, fetching a ball when
// work is ready, head-tilting when one needs a yes, napping when all is clear.
// Reads ~/.agent-board/state.json, written by bin/agent-board-event.
// `AgentBoard --snapshot <dir>` renders preview PNGs instead of running the app.

import AppKit
import SwiftUI

let boardDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-board")
let stateURL = boardDir.appendingPathComponent("state.json")
let lockPath = boardDir.appendingPathComponent("state.lock").path

// MARK: - Palette

extension Color {
    static let ready = Color(red: 0.45, green: 0.86, blue: 0.63)
    static let cooking = Color(red: 0.96, green: 0.77, blue: 0.45)
    static let ask = Color(red: 1.00, green: 0.55, blue: 0.62)
    static let violet = Color(red: 0.68, green: 0.62, blue: 1.00)
    static let ink = Color(red: 0.17, green: 0.11, blue: 0.10)
}

enum Mood {
    case cooking, ready, asking, sleeping
    var color: Color {
        switch self {
        case .cooking: return .cooking
        case .ready: return .ready
        case .asking: return .ask
        case .sleeping: return .violet
        }
    }
    /// One thin streak of the accent colour that travels around a neutral hairline.
    var aura: [Color] {
        if self == .sleeping { return [.clear, .clear] }
        return [color.opacity(0), color.opacity(0), color.opacity(0), color.opacity(0.95), color.opacity(0)]
    }
}

// MARK: - Time-driven animation (frozen for snapshots, paused when hidden)

struct FrozenTimeKey: EnvironmentKey { static let defaultValue: Double? = nil }
struct PausedKey: EnvironmentKey { static let defaultValue = false }
struct CalmKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var frozenTime: Double? { get { self[FrozenTimeKey.self] } set { self[FrozenTimeKey.self] = newValue } }
    var paused: Bool { get { self[PausedKey.self] } set { self[PausedKey.self] = newValue } }
    /// Nothing has happened for a while: only the dog keeps moving, slowly, to save battery.
    var calm: Bool { get { self[CalmKey.self] } set { self[CalmKey.self] = newValue } }
}

let debugOnly = ProcessInfo.processInfo.environment["AB_ONLY"] // profiling: animate one tagged part

struct Animated<Content: View>: View {
    @Environment(\.frozenTime) private var frozen
    @Environment(\.paused) private var paused
    @Environment(\.calm) private var calm
    var fps: Double = 30
    var tag = ""
    @ViewBuilder let content: (Double) -> Content
    var body: some View {
        if let only = debugOnly, only != tag {
            content(1)
        } else if let frozen {
            content(frozen)
        } else {
            TimelineView(.animation(minimumInterval: 1 / (calm ? min(fps, 8) : fps), paused: paused || (calm && tag != "dog"))) { ctx in
                content(ctx.date.timeIntervalSinceReferenceDate)
            }
        }
    }
}

func frac(_ x: Double) -> Double { x - floor(x) }

// MARK: - Model

struct AgentTask: Identifiable, Equatable {
    let id: String
    var source, project, prompt, reply, status, outcome, term, tty, thread, cwd, name, short: String
    var seen: Bool
    var started, finished, updated: Double
    var pids: [Int]
    var herdr: [String: String]   // HERDR_* env when the agent runs inside Herdr

    init(id: String, _ d: [String: Any]) {
        self.id = id
        func s(_ k: String) -> String { d[k] as? String ?? "" }
        source = s("source"); project = s("project"); prompt = s("prompt"); reply = s("reply")
        status = d["status"] as? String ?? "running"; outcome = s("outcome"); term = s("term")
        tty = s("tty"); thread = s("thread"); cwd = s("cwd"); name = s("name"); short = s("title")
        seen = d["seen"] as? Bool ?? false
        started = d["started"] as? Double ?? 0
        finished = d["finished"] as? Double ?? 0
        updated = d["updated"] as? Double ?? 0
        pids = d["pids"] as? [Int] ?? []
        herdr = d["herdr"] as? [String: String] ?? [:]
    }

    var isStale: Bool { status == "running" && Date().timeIntervalSince1970 - updated > 3 * 3600 }
    var isCooking: Bool { status == "running" && !isStale }
    var isReady: Bool { status == "done" && !seen }
    var isAsking: Bool { status == "waiting" && !seen }
    var needsYou: Bool { isReady || isAsking }

    /// Three words on what the request is about (summarised by the hook script).
    var title: String {
        if !short.isEmpty { return short }
        let words = prompt.split(separator: " ").prefix(3).joined(separator: " ")
        return words.isEmpty ? "New task" : words.prefix(1).uppercased() + words.dropFirst()
    }
    var appName: String { ["claude": "Claude", "claudeapp": "Claude", "cursor": "Cursor", "codex": "Codex"][source] ?? source.capitalized }
    var place: String { name.isEmpty ? project.replacingOccurrences(of: "_", with: " ") : name }
}

// MARK: - Store

final class Store: ObservableObject {
    @Published var tasks: [AgentTask] = []
    @Published var collapsed = UserDefaults.standard.bool(forKey: "collapsed") {
        didSet { UserDefaults.standard.set(collapsed, forKey: "collapsed") }
    }
    /// "card" (the default) or "rail"
    @Published var layout = UserDefaults.standard.string(forKey: "layout") ?? "card" {
        didSet { UserDefaults.standard.set(layout, forKey: "layout"); onLayoutChange?(layout) }
    }
    @Published var now = Date()
    @Published var celebrating = Set<String>()
    @Published var visible = true
    @Published var calm = false
    var lastActivity = Date()
    func poke() { lastActivity = Date(); if calm { calm = false } }
    private var lastStamp: Date?
    private var knownReady = Set<String>()
    private var knownStarts = Set<String>()
    private var primed = false
    var onSummon: (() -> Void)?
    var onLayoutChange: ((String) -> Void)?
    var onResize: ((CGSize) -> Void)?
    var onDrag: ((Bool) -> Void)?   // true while dragging, false on release
    @Published var railOpen = false
    var railSize: CGSize = .zero
    var drawerSize: CGSize = .zero
    var onDismiss: (() -> Void)?

    init(live: Bool = true) {
        guard live else { return }
        try? FileManager.default.createDirectory(at: boardDir, withIntermediateDirectories: true)
        load()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.now = Date()
            self.load()
            let c = Date().timeIntervalSince(self.lastActivity) > 60
            if c != self.calm { self.calm = c }
        }
    }

    var cooking: Int { tasks.filter(\.isCooking).count }
    var ready: Int { tasks.filter(\.isReady).count }
    var asking: Int { tasks.filter(\.isAsking).count }
    var mood: Mood { asking > 0 ? .asking : ready > 0 ? .ready : cooking > 0 ? .cooking : .sleeping }
    var longestCook: Double? { tasks.filter(\.isCooking).map(\.started).min() }

    func load() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: stateURL.path))?[.modificationDate] as? Date
        guard stamp != lastStamp else { return }
        lastStamp = stamp
        guard let data = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["tasks"] as? [String: [String: Any]] else {
            tasks = []; return
        }
        let list = raw.map { AgentTask(id: $0.key, $0.value) }
        func rank(_ t: AgentTask) -> Int { t.isAsking ? 0 : t.isReady ? 1 : t.isCooking ? 2 : 3 }
        let sorted = list.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.updated > $1.updated }

        // Something finished or needs a yes: chime, confetti, and pop the board back up.
        let readyNow = Set(list.filter(\.needsYou).map { "\($0.id)@\($0.updated)" })
        let fresh = readyNow.subtracting(knownReady)
        // A new prompt went out in any tool: pop the board back up too.
        let startsNow = Set(list.filter(\.isCooking).map { "\($0.id)@\($0.started)" })
        let newStarts = startsNow.subtracting(knownStarts)
        if primed {
            if !fresh.isEmpty {
                NSSound(named: "Glass")?.play()
                let ids = Set(fresh.map { String($0.split(separator: "@").first ?? "") })
                celebrating.formUnion(ids)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { self.celebrating.subtract(ids) }
            }
            if !fresh.isEmpty || !newStarts.isEmpty { onSummon?() }
        }
        knownReady = readyNow
        knownStarts = startsNow
        primed = true
        if sorted != tasks {
            poke()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { tasks = sorted }
        }
    }

    /// Edit state.json under the same flock the hook script uses.
    func mutate(_ body: (inout [String: [String: Any]]) -> Void) {
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        var obj = (try? Data(contentsOf: stateURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var raw = obj["tasks"] as? [String: [String: Any]] ?? [:]
        body(&raw)
        obj["tasks"] = raw
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: stateURL, options: .atomic)
        }
        lastStamp = nil
        load()
    }

    func remove(_ id: String) { mutate { $0[id] = nil } }
    func clearDone() {
        mutate { raw in
            for (k, v) in raw where (v["status"] as? String) == "done" || (v["seen"] as? Bool ?? false) { raw[k] = nil }
        }
    }

    /// Take the user to the exact place the task lives, then mark it seen.
    func jump(to t: AgentTask) {
        jumpLog("jump: \(t.title) [\(t.source), term \(t.term), herdr pane \(t.herdr["HERDR_PANE_ID"] ?? "none")]")
        if t.needsYou { mutate { $0[t.id]?["seen"] = true } }
        let ws = NSWorkspace.shared
        let folder = t.cwd.isEmpty ? nil : URL(fileURLWithPath: t.cwd)

        func openFolder(inApp path: String) {
            let app = URL(fileURLWithPath: path)
            if let folder {
                ws.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                ws.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        }

        // Inside Herdr: use the recorded pane, or for sessions recorded before Herdr tracking,
        // the pane of a newer session on the same terminal.
        var herdr = t.herdr
        if herdr["HERDR_PANE_ID"] == nil, !t.tty.isEmpty,
           let sibling = tasks.filter({ $0.tty == t.tty && $0.herdr["HERDR_PANE_ID"] != nil }).max(by: { $0.updated < $1.updated }) {
            herdr = sibling.herdr
        }
        if let pane = herdr["HERDR_PANE_ID"] {
            var target = t
            target.herdr = herdr
            focusHerdr(pane: pane, task: target)
            return
        }

        switch t.source {
        case "claudeapp":
            // the accessibility helper presses this chat in Claude's sidebar
            try? t.name.write(to: boardDir.appendingPathComponent("ax-open"), atomically: true, encoding: .utf8)
            ws.openApplication(at: URL(fileURLWithPath: "/Applications/Claude.app"), configuration: .init())
        case "codex":
            if !t.thread.isEmpty, let url = URL(string: "codex://threads/\(t.thread)") { ws.open(url) }
            else { ws.openApplication(at: URL(fileURLWithPath: "/Applications/ChatGPT.app"), configuration: .init()) }
        case "cursor":
            openFolder(inApp: "/Applications/Cursor.app")
        default: // Claude Code: jump back to the terminal it runs in
            switch t.term {
            case "vscode":
                // bring the project window forward, then the Agent Board Jump extension shows the exact terminal tab
                openFolder(inApp: "/Applications/Cursor.app")
                if !t.pids.isEmpty, let url = URL(string: "cursor://agentboard.agent-board-jump/focus?pids=" + t.pids.map(String.init).joined(separator: ",")) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ws.open(url) }
                }
            case "Apple_Terminal": focusTab(app: "Terminal", tty: t.tty)
            case "iTerm.app": focusTab(app: "iTerm", tty: t.tty)
            case "": ws.openApplication(at: URL(fileURLWithPath: "/Applications/Claude.app"), configuration: .init())
            default: ws.launchApplication(["WarpTerminal": "Warp", "ghostty": "Ghostty"][t.term] ?? "Terminal")
            }
        }
    }

    /// Herdr runs inside a terminal app: bring that terminal tab forward, then have Herdr switch to the pane.
    private func focusHerdr(pane: String, task t: AgentTask) {
        let host = ["iTerm.app": "iTerm", "WarpTerminal": "Warp", "ghostty": "Ghostty", "WezTerm": "WezTerm"][t.term] ?? "Terminal"
        DispatchQueue.global().async {
            // the terminal tab where the Herdr client is attached
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-axo", "tty=,ucomm="] // short names keep the output small
            let out = Pipe(); ps.standardOutput = out
            try? ps.run()
            // read before waiting: a full pipe (64 KB) would otherwise deadlock ps and this click
            let rows = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            ps.waitUntilExit()
            let clientTTY = rows.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, parts[0] != "??", parts[1] == "herdr" else { return nil }
                return "/dev/" + parts[0]
            }.first
            jumpLog("herdr click: pane \(pane), host \(host), herdr client tab \(clientTTY ?? "not found")")
            DispatchQueue.main.async {
                if let tty = clientTTY, host == "Terminal" || host == "iTerm" { self.focusTab(app: host, tty: tty) }
                else { NSWorkspace.shared.launchApplication(host) }
            }

            let herdr = t.herdr["HERDR_BIN_PATH"] ?? ["~/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
                .map { NSString(string: $0).expandingTildeInPath }
                .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "herdr"
            func run(_ args: [String]) -> Bool {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: herdr)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                for (k, v) in t.herdr { env[k] = v } // talk to the same Herdr session the agent runs in
                p.environment = env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                do { try p.run() } catch { jumpLog("  herdr \(args.joined(separator: " ")): failed to launch: \(error)"); return false }
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                jumpLog("  herdr \(args.joined(separator: " ")) -> exit \(p.terminationStatus): \(text.prefix(400))")
                return p.terminationStatus == 0
            }
            if !run(["agent", "focus", pane]) {
                if let ws = t.herdr["HERDR_WORKSPACE_ID"] { _ = run(["workspace", "focus", ws]) }
                if let tab = t.herdr["HERDR_TAB_ID"] { _ = run(["tab", "focus", tab]) }
            }
        }
    }

    private func focusTab(app: String, tty: String) {
        let script: String
        if app == "iTerm" {
            script = """
            tell application "iTerm"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      select t
                      select s
                    end if
                  end repeat
                end repeat
              end repeat
              activate
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
              set found to "no matching tab"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    set found to "focused"
                  end if
                end repeat
              end repeat
              activate
              return found
            end tell
            """
        }
        DispatchQueue.global().async {
            var err: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
            jumpLog("  \(app) tab \(tty): \(err.map { "AppleScript error \($0)" } ?? result?.stringValue ?? "done")")
        }
    }
}

// MARK: - Helpers

/// Append a line to ~/.agent-board/jump.log (what each click did; used to debug jumps).
func jumpLog(_ line: String) {
    let url = boardDir.appendingPathComponent("jump.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    let data = Data("\(stamp) \(line)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
    else { try? data.write(to: url) }
}

enum Icons {
    static var cache: [String: NSImage] = [:]
    static func app(_ source: String) -> NSImage {
        let path = ["claude": "/Applications/Claude.app", "claudeapp": "/Applications/Claude.app", "cursor": "/Applications/Cursor.app",
                    "codex": "/Applications/ChatGPT.app"][source] ?? "/System/Applications/Utilities/Terminal.app"
        if let img = cache[path] { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache[path] = img
        return img
    }
}

func ago(_ ts: Double, _ now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince1970 - ts))
    if s < 45 { return "just now" }
    if s < 3600 { return "\(max(1, s / 60))m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}

func duration(_ from: Double, _ now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince1970 - from))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}

// MARK: - The dog

struct Dog: View {
    let mood: Mood
    var body: some View {
        Animated(fps: mood == .sleeping ? 10 : 20, tag: "dog") { t in
            Canvas { ctx, size in
                ctx.scaleBy(x: size.width / 132, y: size.height / 100)
                DogPainter(mood: mood, t: t).paint(&ctx)
            }
        }
        .drawingGroup()
    }
}

/// A Doberman in side profile, drawn as a flat premium illustration.
/// Design space is 132 x 100; the dog faces right, toward the laptop.
struct DogPainter {
    let mood: Mood
    let t: Double

    let coat = Color(red: 0.09, green: 0.08, blue: 0.09)
    let sheen = Color(red: 0.30, green: 0.27, blue: 0.29)
    let tan = Color(red: 0.74, green: 0.41, blue: 0.18)
    let tanDeep = Color(red: 0.55, green: 0.28, blue: 0.11)
    let rim = Color.white.opacity(0.17)

    func s(_ speed: Double, _ phase: Double = 0) -> CGFloat { CGFloat(sin(t * speed + phase)) }
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path { Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h)) }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path { oval(x - r, y - r, r * 2, r * 2) }
    var coatFill: GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [sheen, coat, coat]), startPoint: pt(40, 10), endPoint: pt(70, 90))
    }

    // MARK: Shapes

    /// Sitting body, including the far front leg and the hind leg.
    var sittingBody: Path {
        var p = Path()
        p.move(to: pt(31, 68))
        p.addCurve(to: pt(54, 40), control1: pt(34, 55), control2: pt(45, 45))       // back
        p.addCurve(to: pt(61, 22), control1: pt(58, 36), control2: pt(57, 27))       // arched neck
        p.addLine(to: pt(68, 31))                                                     // under the jaw
        p.addCurve(to: pt(73, 55), control1: pt(71, 38), control2: pt(75, 47))       // throat into deep chest
        p.addLine(to: pt(70.5, 62))
        p.addLine(to: pt(70.5, 87.5))                                                 // far front leg
        p.addQuadCurve(to: pt(74, 90), control: pt(71, 90))
        p.addLine(to: pt(64.5, 90))
        p.addLine(to: pt(65, 65))
        p.addCurve(to: pt(57.5, 72), control1: pt(62, 67), control2: pt(59.5, 68))  // tucked belly
        p.addCurve(to: pt(60, 87), control1: pt(57, 78), control2: pt(60, 82))      // hind leg front
        p.addQuadCurve(to: pt(62, 90), control: pt(62, 89))                          // hind paw
        p.addLine(to: pt(43, 90))
        p.addCurve(to: pt(31, 68), control1: pt(29, 90), control2: pt(25, 77))      // haunch and rump
        p.closeSubpath()
        return p
    }

    /// Wedge-shaped head with a long muzzle (absolute coordinates, sitting pose).
    var headShape: Path {
        var p = Path()
        p.move(to: pt(60, 21))
        p.addCurve(to: pt(72, 15.5), control1: pt(63, 16), control2: pt(68, 15))    // skull
        p.addCurve(to: pt(88, 22.5), control1: pt(78, 16.5), control2: pt(85, 19.5)) // long muzzle
        p.addCurve(to: pt(88, 27), control1: pt(90.2, 23.5), control2: pt(90.2, 26.3)) // nose
        p.addCurve(to: pt(70, 33), control1: pt(81, 29), control2: pt(74, 33))      // lips and chin
        p.addCurve(to: pt(62, 30), control1: pt(66, 33.5), control2: pt(63.5, 32))  // jaw
        p.addCurve(to: pt(60, 21), control1: pt(60, 27), control2: pt(59, 24))
        p.closeSubpath()
        return p
    }

    var earShape: Path {
        var p = Path()
        p.move(to: pt(60.5, 21))
        p.addCurve(to: pt(61.8, 0.5), control1: pt(58.5, 13), control2: pt(59.3, 5))
        p.addCurve(to: pt(68.5, 17), control1: pt(65.5, 4), control2: pt(68, 10))
        p.closeSubpath()
        return p
    }

    // MARK: Paint

    func paint(_ ctx: inout GraphicsContext) {
        let hop: CGFloat = mood == .ready ? -abs(s(5.5)) * 4 : 0
        ctx.fill(oval(18 - hop, 88.5, mood == .sleeping ? 96 : 66 + hop * 2, 5), with: .color(.black.opacity(0.35)))
        if mood == .sleeping { lying(&ctx); zzz(&ctx); return }

        var d = ctx
        d.translateBy(x: 0, y: hop)
        tail(&d, at: pt(31, 68))
        // far front leg sits a touch darker, then the body over it
        d.fill(sittingBody, with: coatFill)
        d.stroke(sittingBody, with: .color(rim), lineWidth: 0.8)
        bodyMarkings(&d)
        head(&d)
        nearLeg(&d)
        if mood == .cooking || mood == .asking { laptop(&ctx) }
        switch mood {
        case .cooking: screenLight(&ctx); codeBits(&ctx); tapLines(&ctx)
        case .ready: sparkles(&ctx)
        case .asking: screenLight(&ctx); bubble(&ctx)
        case .sleeping: break
        }
    }

    func bodyMarkings(_ d: inout GraphicsContext) {
        var c = d
        c.clip(to: sittingBody)
        c.fill(oval(66.5, 38, 6.5, 9), with: .color(tan))                             // chest spot
        c.fill(Path(CGRect(x: 63, y: 78, width: 14, height: 13)), with: .linearGradient(
            Gradient(colors: [tan.opacity(0), tan]), startPoint: pt(0, 76), endPoint: pt(0, 83)))  // far forefoot
        c.fill(Path(CGRect(x: 42, y: 85, width: 22, height: 6)), with: .linearGradient(
            Gradient(colors: [tan.opacity(0), tan]), startPoint: pt(0, 84), endPoint: pt(0, 88)))  // hind foot
        c.fill(oval(26, 70, 7, 6), with: .color(tan.opacity(0.85)))                    // under the tail
        // glossy highlight along the back
        var hl = Path()
        hl.move(to: pt(36, 60)); hl.addCurve(to: pt(56, 32), control1: pt(40, 48), control2: pt(50, 40))
        c.stroke(hl, with: .color(.white.opacity(0.10)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }

    func head(_ d: inout GraphicsContext) {
        var h = d
        let tilt: Double
        switch mood {
        case .cooking: tilt = 4 + Double(s(16)) * 1.6        // focused nodding at the screen
        case .asking: tilt = -14 + Double(s(1.5)) * 2        // the classic head tilt
        case .ready: tilt = -4
        case .sleeping: tilt = 0
        }
        h.translateBy(x: 63, y: 28); h.rotate(by: .degrees(tilt)); h.translateBy(x: -63, y: -28)

        // ear, with a twitch
        var e = h
        let twitch: Double = mood == .cooking ? (frac(t / 2.3) > 0.9 ? Double(s(40)) * 5 : 0) : (mood == .asking ? 8 : 0)
        e.translateBy(x: 64, y: 19); e.rotate(by: .degrees(twitch)); e.translateBy(x: -64, y: -19)
        e.fill(earShape, with: .linearGradient(Gradient(colors: [sheen, coat]), startPoint: pt(62, 1), endPoint: pt(64, 20)))
        e.stroke(earShape, with: .color(rim), lineWidth: 0.8)
        var inner = Path()
        inner.move(to: pt(62.3, 18)); inner.addCurve(to: pt(62.3, 5), control1: pt(61.3, 12), control2: pt(61.5, 8))
        inner.addCurve(to: pt(66.3, 16.5), control1: pt(64.5, 8), control2: pt(66, 12)); inner.closeSubpath()
        e.fill(inner, with: .color(Color(red: 0.36, green: 0.24, blue: 0.24)))

        h.fill(headShape, with: .linearGradient(Gradient(colors: [sheen, coat]), startPoint: pt(66, 14), endPoint: pt(72, 30)))
        h.stroke(headShape, with: .color(rim), lineWidth: 0.8)

        // tan points: muzzle and lips, cheek, eyebrow
        var m = h
        m.clip(to: headShape)
        var muzzle = Path()
        muzzle.move(to: pt(74, 24.5)); muzzle.addCurve(to: pt(89, 26), control1: pt(80, 24), control2: pt(85, 25))
        muzzle.addLine(to: pt(89, 34)); muzzle.addLine(to: pt(67, 34))
        muzzle.addCurve(to: pt(74, 24.5), control1: pt(68, 29), control2: pt(71, 25.5)); muzzle.closeSubpath()
        m.fill(muzzle, with: .linearGradient(Gradient(colors: [tan, tanDeep]), startPoint: pt(78, 24), endPoint: pt(78, 33)))
        m.fill(oval(64.5, 25.5, 6, 5), with: .color(tan.opacity(0.9)))
        m.fill(oval(70.2, 16.4, 3.6, 2), with: .color(tan))
        m.fill(oval(66, 16.5, 12, 3), with: .color(.white.opacity(0.08)))       // skull sheen

        // almond eye
        let blink = frac(t / 3.3) > 0.96
        if blink || mood == .sleeping {
            h.stroke(Path { $0.move(to: pt(71.5, 21)); $0.addQuadCurve(to: pt(76, 21), control: pt(73.7, 22.2)) },
                     with: .color(.black), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        } else {
            var eye = Path()
            eye.move(to: pt(71.2, 21.1)); eye.addQuadCurve(to: pt(76.2, 20.6), control: pt(73.6, 18.9))
            eye.addQuadCurve(to: pt(71.2, 21.1), control: pt(73.8, 22.6)); eye.closeSubpath()
            h.fill(eye, with: .color(Color(red: 0.36, green: 0.20, blue: 0.08)))
            h.fill(circle(74, 20.9, 0.95), with: .color(.black))
            h.fill(circle(74.4, 20.4, 0.38), with: .color(.white.opacity(0.95)))
            if mood == .cooking { h.fill(circle(75.2, 20.6, 0.3), with: .color(Color.cooking.opacity(0.9))) } // screen reflection
        }

        // nose and mouth
        h.fill(oval(85.6, 21.4, 4, 3.4), with: .color(.black))
        h.fill(oval(86.6, 21.9, 1.4, 0.8), with: .color(.white.opacity(0.45)))
        var lip = Path()
        lip.move(to: pt(88.2, 27)); lip.addCurve(to: pt(77.5, 29.6), control1: pt(85, 28.6), control2: pt(80.5, 29.4))
        h.stroke(lip, with: .color(Color(red: 0.12, green: 0.07, blue: 0.05)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))

        switch mood {
        case .cooking:
            let pant = (s(10) + 1) * 0.7
            h.fill(Path(roundedRect: CGRect(x: 79.5, y: 29, width: 3.4, height: 3.2 + pant), cornerRadius: 1.7),
                   with: .color(Color(red: 0.86, green: 0.40, blue: 0.48)))
        case .ready:
            let ball = circle(85, 30, 4.6)
            h.fill(ball, with: .radialGradient(Gradient(colors: [Color(red: 0.93, green: 1, blue: 0.45), Color(red: 0.68, green: 0.82, blue: 0.10)]),
                                               center: pt(83.5, 28.5), startRadius: 0, endRadius: 6))
            h.stroke(Path { $0.move(to: pt(82, 26.3)); $0.addQuadCurve(to: pt(82.3, 33.6), control: pt(86, 30)) },
                     with: .color(.white.opacity(0.85)), lineWidth: 0.8)
        default: break
        }
    }

    /// Near front leg: straight when sitting, reaching out to the keys when cooking.
    func nearLeg(_ d: inout GraphicsContext) {
        let shoulder = pt(68, 54)
        var elbow = pt(70, 70), paw = pt(73, 88)
        if mood == .cooking {
            let tap = max(0, s(17)) * 3.2
            elbow = pt(77, 70); paw = pt(92, 84.5 - tap)
        } else if mood == .asking {
            elbow = pt(77, 70); paw = pt(92, 85)
        }
        var leg = Path()
        leg.move(to: shoulder); leg.addQuadCurve(to: paw, control: elbow)
        d.stroke(leg, with: .color(rim), style: StrokeStyle(lineWidth: 7.2, lineCap: .round))
        d.stroke(leg, with: .color(coat), style: StrokeStyle(lineWidth: 6.2, lineCap: .round))
        // tan lower leg and paw
        var lower = Path()
        let mid = pt((elbow.x + paw.x * 2) / 3, (elbow.y + paw.y * 2) / 3)
        lower.move(to: mid); lower.addLine(to: paw)
        d.stroke(lower, with: .color(tan), style: StrokeStyle(lineWidth: 5.4, lineCap: .round))
        d.fill(oval(paw.x - 3.6, paw.y - 2.2, 7.2, 4.4), with: .color(tan))
        d.stroke(Path { $0.move(to: pt(paw.x + 0.5, paw.y - 1.6)); $0.addLine(to: pt(paw.x + 0.5, paw.y + 1.6)) },
                 with: .color(tanDeep), lineWidth: 0.6)
    }

    func tail(_ d: inout GraphicsContext, at base: CGPoint) {
        let wag: Double
        switch mood {
        case .cooking: wag = Double(s(12)) * 18
        case .ready: wag = Double(s(22)) * 28
        case .asking: wag = Double(s(3)) * 10
        case .sleeping: wag = 0
        }
        var c = d
        c.translateBy(x: base.x, y: base.y); c.rotate(by: .degrees(wag))
        let p = Path { $0.move(to: .zero); $0.addLine(to: pt(-5.5, -5)) }
        c.stroke(p, with: .color(rim), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        c.stroke(p, with: .color(coat), style: StrokeStyle(lineWidth: 4, lineCap: .round))
    }

    // MARK: Lying down (idle)

    func lying(_ ctx: inout GraphicsContext) {
        let b = s(1.6) * 0.6
        let bed = Path(roundedRect: CGRect(x: 10, y: 82, width: 112, height: 11), cornerRadius: 5.5)
        ctx.fill(bed, with: .linearGradient(Gradient(colors: [Color(red: 0.36, green: 0.30, blue: 0.62), Color(red: 0.20, green: 0.16, blue: 0.38)]),
                                            startPoint: pt(0, 82), endPoint: pt(0, 93)))
        ctx.stroke(Path { $0.move(to: pt(16, 82.6)); $0.addLine(to: pt(116, 82.6)) }, with: .color(.white.opacity(0.15)), lineWidth: 0.8)

        var body = Path()
        body.move(to: pt(26, 84))
        body.addCurve(to: pt(30, 64 - b), control1: pt(18, 80), control2: pt(20, 66 - b))   // rump
        body.addCurve(to: pt(66, 62 - b), control1: pt(42, 60 - b), control2: pt(56, 58 - b)) // back
        body.addCurve(to: pt(74, 76), control1: pt(72, 64), control2: pt(75, 70))           // shoulder
        body.addLine(to: pt(74, 84))
        body.closeSubpath()
        tail(&ctx, at: pt(27, 70))
        ctx.fill(body, with: .linearGradient(Gradient(colors: [sheen, coat]), startPoint: pt(40, 58), endPoint: pt(48, 84)))
        ctx.stroke(body, with: .color(rim), lineWidth: 0.8)
        var marks = ctx
        marks.clip(to: body)
        marks.fill(oval(24, 72, 18, 14), with: .color(.white.opacity(0.05)))                // haunch
        marks.stroke(Path { $0.move(to: pt(34, 66 - b)); $0.addCurve(to: pt(62, 62 - b), control1: pt(42, 62), control2: pt(54, 60)) },
                     with: .color(.white.opacity(0.10)), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        // front legs stretched forward, tan paws
        let legs = Path(roundedRect: CGRect(x: 66, y: 79, width: 42, height: 5.4), cornerRadius: 2.7)
        ctx.fill(legs, with: .color(coat))
        ctx.stroke(legs, with: .color(rim), lineWidth: 0.7)
        ctx.fill(Path(roundedRect: CGRect(x: 96, y: 79, width: 13, height: 5.4), cornerRadius: 2.7), with: .color(tan))

        // head resting on the paws, ears relaxed back
        var h = ctx
        h.translateBy(x: 14, y: 50)
        h.translateBy(x: 63, y: 28); h.rotate(by: .degrees(6)); h.translateBy(x: -63, y: -28)
        var e = h
        e.translateBy(x: 64, y: 19); e.rotate(by: .degrees(-38)); e.translateBy(x: -64, y: -19)
        e.fill(earShape, with: .linearGradient(Gradient(colors: [sheen, coat]), startPoint: pt(62, 1), endPoint: pt(64, 20)))
        e.stroke(earShape, with: .color(rim), lineWidth: 0.8)
        h.fill(headShape, with: .linearGradient(Gradient(colors: [sheen, coat]), startPoint: pt(66, 14), endPoint: pt(72, 30)))
        h.stroke(headShape, with: .color(rim), lineWidth: 0.8)
        var m = h
        m.clip(to: headShape)
        var muzzle = Path()
        muzzle.move(to: pt(74, 24.5)); muzzle.addCurve(to: pt(89, 26), control1: pt(80, 24), control2: pt(85, 25))
        muzzle.addLine(to: pt(89, 34)); muzzle.addLine(to: pt(67, 34))
        muzzle.addCurve(to: pt(74, 24.5), control1: pt(68, 29), control2: pt(71, 25.5)); muzzle.closeSubpath()
        m.fill(muzzle, with: .color(tan))
        m.fill(oval(70.2, 16.4, 3.6, 2), with: .color(tan))
        h.stroke(Path { $0.move(to: pt(71.5, 21)); $0.addQuadCurve(to: pt(76, 21), control: pt(73.7, 22.4)) },
                 with: .color(.black), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        h.fill(oval(85.6, 21.4, 4, 3.4), with: .color(.black))
    }

    // MARK: Props and effects

    func laptop(_ ctx: inout GraphicsContext) {
        let base = Path(roundedRect: CGRect(x: 84, y: 87, width: 36, height: 3.2), cornerRadius: 1.6)
        ctx.fill(base, with: .linearGradient(Gradient(colors: [Color(white: 0.78), Color(white: 0.48)]), startPoint: pt(0, 87), endPoint: pt(0, 90)))
        for i in 0..<7 { ctx.fill(Path(CGRect(x: 88 + CGFloat(i) * 3.8, y: 87.4, width: 2.6, height: 0.6)), with: .color(Color(white: 0.35))) }
        var lid = Path()
        lid.move(to: pt(116.5, 88)); lid.addLine(to: pt(119, 88)); lid.addLine(to: pt(126, 60)); lid.addLine(to: pt(123.5, 60)); lid.closeSubpath()
        ctx.fill(lid, with: .color(Color(white: 0.55)))
        // lit screen face, toward the dog
        let flicker = 0.75 + 0.25 * Double(abs(s(9)))
        ctx.stroke(Path { $0.move(to: pt(116.6, 86)); $0.addLine(to: pt(123.2, 61)) },
                   with: .color(mood.color.opacity(flicker)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }

    func screenLight(_ ctx: inout GraphicsContext) {
        var c = ctx
        c.blendMode = .screen
        var beam = Path()
        beam.move(to: pt(123, 61)); beam.addLine(to: pt(117, 86)); beam.addLine(to: pt(70, 60)); beam.addLine(to: pt(74, 8)); beam.closeSubpath()
        let k = 0.16 + 0.05 * Double(s(9))
        c.fill(beam, with: .linearGradient(Gradient(colors: [mood.color.opacity(k), mood.color.opacity(0)]), startPoint: pt(120, 70), endPoint: pt(72, 40)))
    }

    func tapLines(_ ctx: inout GraphicsContext) {
        guard s(17) > 0.3 else { return }
        for (dx, dy) in [(CGFloat(-3), CGFloat(-5)), (0, -6.5), (3, -5)] {
            ctx.stroke(Path { $0.move(to: pt(92 + dx, 80 + dy)); $0.addLine(to: pt(92 + dx * 1.5, 80 + dy * 1.4)) },
                       with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        }
    }

    func codeBits(_ ctx: inout GraphicsContext) {
        let glyphs = ["</>", "{ }", "01", "=>", "✓"]
        let colors: [Color] = [.white, mood.color, .white, .white, mood.color]
        for i in 0..<glyphs.count {
            let ph = frac(t * 0.6 + Double(i) / Double(glyphs.count))
            let x = 112 - CGFloat(ph) * 14 + CGFloat(sin(ph * 6 + Double(i))) * 3
            let y = 58 - CGFloat(ph) * 50
            var c = ctx
            c.opacity = sin(ph * .pi) * 0.9
            c.draw(Text(glyphs[i]).font(.system(size: 7, weight: .bold, design: .monospaced)).foregroundColor(colors[i]), at: pt(x, y))
        }
    }

    func sparkles(_ ctx: inout GraphicsContext) {
        let spots: [(CGFloat, CGFloat, Color)] = [(100, 18, .white), (112, 48, mood.color), (18, 30, .white), (96, 66, mood.color)]
        for (i, sp) in spots.enumerated() {
            let k = 0.4 + 0.6 * abs(sin(t * 3.5 + Double(i) * 1.4))
            var c = ctx
            c.opacity = k
            c.draw(Text("✦").font(.system(size: 6 + 6 * k)).foregroundColor(sp.2), at: pt(sp.0, sp.1))
        }
    }

    func bubble(_ ctx: inout GraphicsContext) {
        let by = 12 + s(2) * 1.5
        ctx.fill(circle(110, by, 9), with: .color(.white))
        ctx.fill(circle(99.5, by + 8, 2), with: .color(.white))
        ctx.fill(circle(95.5, by + 11, 1.2), with: .color(.white))
        ctx.draw(Text("?").font(.system(size: 12, weight: .black, design: .rounded)).foregroundColor(.ask), at: pt(110, by))
    }

    func zzz(_ ctx: inout GraphicsContext) {
        for i in 0..<3 {
            let ph = frac(t * 0.33 + Double(i) / 3)
            var c = ctx
            c.opacity = sin(ph * .pi)
            c.draw(Text("z").font(.system(size: 6 + 7 * ph, weight: .heavy, design: .rounded)).foregroundColor(Color(red: 0.75, green: 0.7, blue: 1)),
                   at: pt(104 + CGFloat(ph) * 14, 62 - CGFloat(ph) * 34))
        }
    }
}

// MARK: - Status

struct StatusLabel: View {
    let task: AgentTask
    @Environment(\.frozenTime) private var frozen

    var body: some View {
        HStack(spacing: 6) {
            if task.isCooking && frozen != nil {
                // snapshots can't draw the native spinner
                Circle().trim(from: 0, to: 0.7).stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .frame(width: 9, height: 9).rotationEffect(.degrees(40))
            } else if task.isCooking {
                ProgressView().progressViewStyle(.circular).controlSize(.mini).scaleEffect(0.8).frame(width: 10, height: 10)
            } else if task.needsYou || task.isStale || !task.outcome.isEmpty {
                Circle().fill(tint).frame(width: 6, height: 6)
                    .shadow(color: tint.opacity(task.needsYou ? 0.8 : 0), radius: 3)
            }
            Text(label)
                .font(.system(size: 11.5, weight: task.needsYou ? .medium : .regular))
                .foregroundStyle(task.needsYou ? tint : .white.opacity(0.42))
        }
        .fixedSize()
    }

    var label: String {
        if task.isStale { return "Stalled" }
        switch task.status {
        case "running": return "In progress"
        case "waiting": return task.seen ? "Waiting" : "Approve"
        default:
            if !task.outcome.isEmpty { return task.outcome == "aborted" ? "Stopped" : "Failed" }
            return task.seen ? "Done" : "Ready"
        }
    }
    var tint: Color {
        if task.isStale { return Color(white: 0.5) }
        switch task.status {
        case "waiting": return .ask
        default: return task.outcome.isEmpty ? .ready : .cooking
        }
    }
}

// MARK: - Frosted glass (blurs whatever is behind the window)

struct Glass: View {
    @Environment(\.frozenTime) private var frozen
    var body: some View {
        if frozen != nil {
            Color(white: 0.16).opacity(0.55) // snapshot renderer can't draw the live blur
        } else {
            GlassView()
        }
    }
}

struct GlassView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

extension View {
    /// Frosted glass with the readability tint, a hairline edge, and the travelling accent streak.
    func boardGlass(radius: CGFloat, mood: Mood) -> some View {
        self
            .background(
                ZStack {
                    Glass()
                    LinearGradient(colors: [Color(red: 0.10, green: 0.09, blue: 0.12).opacity(0.38), Color.black.opacity(0.5)],
                                   startPoint: .top, endPoint: .bottom)
                    RadialGradient(colors: [mood.color.opacity(0.08), .clear], center: .topLeading, startRadius: 0, endRadius: 240)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            )
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .overlay(AuraRing(colors: mood.aura, width: 1, radius: radius))
    }
}

// MARK: - Cheap looping effects (plain SwiftUI animations, no per-frame view rebuilds)

/// Rotating conic gradient ring. Core Animation runs it in the render server, so it costs ~0 CPU.
struct AuraRing: View {
    let colors: [Color]
    let width: CGFloat
    var radius: CGFloat = 22
    @Environment(\.frozenTime) private var frozen
    @Environment(\.calm) private var calm
    @Environment(\.paused) private var paused
    var body: some View {
        if frozen != nil { // snapshot renderer can't draw layers
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(AngularGradient(colors: colors, center: .center), lineWidth: width)
        } else {
            AuraLayer(colors: colors.map { NSColor($0).cgColor }, width: width, radius: radius, spinning: !calm && !paused)
                .allowsHitTesting(false)
        }
    }
}

struct AuraLayer: NSViewRepresentable {
    let colors: [CGColor]
    let width: CGFloat
    let radius: CGFloat
    let spinning: Bool

    final class V: NSView {
        let gradient = CAGradientLayer()
        let ring = CAShapeLayer()
        var radius: CGFloat = 22
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(gradient)
            ring.fillColor = nil
            ring.strokeColor = NSColor.white.cgColor
            layer?.mask = ring
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            let b = bounds, d = max(b.width, b.height) * 1.5
            CATransaction.begin(); CATransaction.setDisableActions(true)
            gradient.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            gradient.position = CGPoint(x: b.midX, y: b.midY)
            ring.frame = b
            let inset = ring.lineWidth / 2
            ring.path = CGPath(roundedRect: b.insetBy(dx: inset, dy: inset), cornerWidth: radius - inset, cornerHeight: radius - inset, transform: nil)
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) {
        v.gradient.colors = colors
        v.ring.lineWidth = width
        v.radius = radius
        v.needsLayout = true
        let spinningNow = v.gradient.animation(forKey: "spin") != nil
        if spinning && !spinningNow {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0; a.toValue = -2 * Double.pi
            a.duration = 5; a.repeatCount = .infinity
            v.gradient.add(a, forKey: "spin")
        } else if !spinning && spinningNow {
            v.gradient.removeAnimation(forKey: "spin")
        }
    }
}

/// Indeterminate "working" bar, also driven by Core Animation.
struct ProgressSweep: View {
    @Environment(\.frozenTime) private var frozen
    var body: some View {
        if let t = frozen {
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.07))
                    .overlay(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: [.cooking.opacity(0), .cooking, .ask], startPoint: .leading, endPoint: .trailing))
                            .frame(width: g.size.width * 0.4)
                            .offset(x: (CGFloat(frac(t * 0.55)) * 1.4 - 0.4) * g.size.width)
                    }
                    .clipShape(Capsule())
            }
        } else {
            SweepLayer().allowsHitTesting(false)
        }
    }
}

struct SweepLayer: NSViewRepresentable {
    final class V: NSView {
        let bar = CAGradientLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
            layer?.masksToBounds = true
            bar.colors = [NSColor(Color.cooking).withAlphaComponent(0).cgColor, NSColor(Color.cooking).cgColor, NSColor(Color.ask).cgColor]
            bar.startPoint = CGPoint(x: 0, y: 0.5); bar.endPoint = CGPoint(x: 1, y: 0.5)
            layer?.addSublayer(bar)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            let b = bounds
            layer?.cornerRadius = b.height / 2
            CATransaction.begin(); CATransaction.setDisableActions(true)
            bar.bounds = CGRect(x: 0, y: 0, width: b.width * 0.4, height: b.height)
            bar.cornerRadius = b.height / 2
            bar.position = CGPoint(x: -b.width * 0.2, y: b.midY)
            CATransaction.commit()
            bar.removeAnimation(forKey: "sweep")
            let a = CABasicAnimation(keyPath: "position.x")
            a.fromValue = -b.width * 0.2; a.toValue = b.width * 1.2
            a.duration = 1.8; a.repeatCount = .infinity
            bar.add(a, forKey: "sweep")
        }
    }
    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) {}
}

// MARK: - Confetti

struct Confetti: View {
    let accent: Color
    @State private var go = false
    private let bits: [(angle: Double, dist: CGFloat, white: Bool, size: CGFloat)] = (0..<14).map { _ in
        (Double.random(in: 0..<360), CGFloat.random(in: 40...120), Bool.random(), CGFloat.random(in: 2...3.5))
    }
    var body: some View {
        ZStack {
            ForEach(0..<bits.count, id: \.self) { i in
                let b = bits[i]
                Circle()
                    .fill(b.white ? Color.white : accent)
                    .frame(width: b.size, height: b.size)
                    .offset(x: go ? cos(b.angle * .pi / 180) * b.dist : 0,
                            y: go ? sin(b.angle * .pi / 180) * b.dist * 0.4 + 10 : 0)
                    .opacity(go ? 0 : 0.9)
            }
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeOut(duration: 1.2)) { go = true } }
    }
}

// MARK: - Task row

struct Row: View {
    let task: AgentTask
    @ObservedObject var store: Store
    @State private var hover = false

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: Icons.app(task.source))
                .resizable().interpolation(.high)
                .frame(width: 22, height: 22)
                .saturation(task.seen && !task.isCooking ? 0 : 1)
                .opacity(task.seen && !task.isCooking ? 0.6 : 1)
            Text(task.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(task.seen && !task.isCooking ? 0.45 : 0.92))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hover {
                Button { store.remove(task.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Remove")
                .transition(.opacity)
            } else {
                StatusLabel(task: task)
            }
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(Rectangle().fill(.white.opacity(hover ? 0.05 : 0)))
        .overlay { if store.celebrating.contains(task.id) { Confetti(accent: task.isAsking ? .ask : .ready) } }
        .animation(.easeOut(duration: 0.15), value: hover)
        .contentShape(Rectangle())
        .onHover { h in
            hover = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture { store.jump(to: task) }
        .help("Open this \(task.appName) chat")
    }
}

// MARK: - Board

struct Board: View {
    @ObservedObject var store: Store
    var peekPreview = false
    @State private var hover = false
    @Environment(\.frozenTime) private var frozen

    var headline: String {
        switch store.mood {
        case .asking: return store.asking == 1 ? "Awaiting approval" : "\(store.asking) awaiting approval"
        case .ready: return "\(store.ready) ready for review"
        case .cooking: return "\(store.cooking) in progress"
        case .sleeping: return "All clear"
        }
    }

    /// Names the task the headline is about, so it's clear which chat is ready or waiting.
    var subline: String {
        let lead: AgentTask?
        switch store.mood {
        case .asking: lead = store.tasks.first(where: \.isAsking)
        case .ready: lead = store.tasks.first(where: \.isReady)
        case .cooking: lead = store.tasks.first(where: \.isCooking)
        case .sleeping: lead = nil
        }
        var parts: [String] = []
        if let lead { parts.append(store.mood == .cooking && store.cooking > 1 ? "\(lead.title) and more" : "\(lead.title) · \(lead.appName)") }
        if store.mood != .asking && store.asking > 0 { parts.append("\(store.asking) awaiting approval") }
        if store.mood != .ready && store.ready > 0 { parts.append("\(store.ready) ready") }
        if store.mood != .cooking && store.cooking > 0 { parts.append("\(store.cooking) in progress") }
        return parts.isEmpty ? "Nothing running right now" : parts.joined(separator: " · ")
    }

    var hero: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(RadialGradient(colors: [store.mood.color.opacity(0.18), .clear], center: .center, startRadius: 2, endRadius: 70))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                Dog(mood: store.mood).padding(.top, 3).padding(.bottom, 1)
            }
            .frame(width: 120, height: 94)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("AGENTS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(store.mood == .sleeping ? .white.opacity(0.35) : store.mood.color.opacity(0.85))
                Text(headline)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(.numericText())
                Text(subline)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .overlay(alignment: .topTrailing) { controls.padding(12) }
    }

    var controls: some View {
        HStack(spacing: 4) {
            iconButton("sidebar.right", help: "Switch to the side rail") {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { store.layout = "rail" }
            }
            iconButton(store.collapsed ? "chevron.down" : "chevron.up", help: store.collapsed ? "Show tasks" : "Hide tasks") {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { store.collapsed.toggle() }
            }
            iconButton("xmark", help: "Dismiss. It comes back when you send a new prompt.") { store.onDismiss?() }
        }
        .opacity(hover ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hover)
    }

    func iconButton(_ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.tasks.enumerated()), id: \.element.id) { i, t in
                if i > 0 { Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5).padding(.leading, 45) }
                Row(task: t, store: store)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    var list: some View {
        VStack(spacing: 0) {
            Group {
                if frozen != nil {
                    rows // ImageRenderer can't draw ScrollView contents
                } else {
                    ScrollView(showsIndicators: false) { rows }
                        .frame(maxHeight: 360)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            HStack {
                Spacer()
                if store.tasks.contains(where: { $0.status == "done" || $0.seen }) {
                    Button("Clear finished") { withAnimation(.easeOut(duration: 0.25)) { store.clearDone() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.38))
                }
            }
            .frame(height: 30)
            .padding(.horizontal, 16)
        }
    }

    var card: some View {
        VStack(spacing: 0) {
            hero
            if !store.collapsed && !store.tasks.isEmpty {
                list.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: 360)
        .boardGlass(radius: 22, mood: store.mood)
    }

    var body: some View {
        Group {
            if store.layout == "rail" { Rail(store: store, peekPreview: peekPreview) } else { card }
        }
            .padding(2)
            .fixedSize()
            .onHover { hover = $0; store.poke() }
            .onContinuousHover { _ in if store.calm { store.poke() } }
            .environment(\.colorScheme, .dark)
            .environment(\.paused, !store.visible)
            .environment(\.calm, store.calm)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { store.onResize?($0) }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { v in
                    if v.translation == .zero || abs(v.translation.width) + abs(v.translation.height) < 4 { jumpLog("drag began") }
                    store.onDrag?(true)
                }
                .onEnded { _ in store.onDrag?(false) })
    }
}

// MARK: - Side rail layout

/// The dog's head, cropped out of the full scene.
struct DogHead: View {
    let mood: Mood
    var size: CGFloat = 34
    var body: some View {
        let lying = mood == .sleeping
        Dog(mood: mood)
            .frame(width: size * 2.6, height: size * 1.97)
            .offset(x: -size * (lying ? 0.47 : 0.18), y: size * (lying ? -0.49 : 0.59))
            .frame(width: size, height: size)
            .background(Circle().fill(RadialGradient(colors: [mood.color.opacity(0.25), .white.opacity(0.04)], center: .center, startRadius: 1, endRadius: size / 2)))
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }
}

struct RailIcon: View {
    let task: AgentTask
    @ObservedObject var store: Store
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: Icons.app(task.source))
                .resizable().interpolation(.high)
                .frame(width: 26, height: 26)
                .saturation(task.seen && !task.isCooking ? 0 : 1)
                .opacity(task.seen && !task.isCooking ? 0.5 : 1)
            if task.isCooking || task.needsYou {
                Circle().fill(task.isCooking ? Color.cooking : task.isAsking ? .ask : .ready)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color(white: 0.08), lineWidth: 1.5))
                    .shadow(color: (task.isAsking ? Color.ask : .ready).opacity(task.needsYou ? 0.9 : 0), radius: 3)
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: 52, height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0)).padding(.horizontal, 6))
        .overlay { if store.celebrating.contains(task.id) { Confetti(accent: task.isAsking ? .ask : .ready) } }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.jump(to: task) }
        .help(task.title)
    }
}

struct Rail: View {
    @ObservedObject var store: Store
    var peekPreview = false
    static let drawerWidth: CGFloat = 290

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // The drawer's space is always reserved, so opening it never resizes the window.
            ZStack(alignment: .topTrailing) {
                if (store.railOpen || peekPreview) && !store.tasks.isEmpty {
                    peek.transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .frame(width: Rail.drawerWidth, alignment: .topTrailing)
            rail.onGeometryChange(for: CGSize.self) { $0.size } action: { store.railSize = $0 }
        }
    }

    var rail: some View {
        VStack(spacing: 0) {
            DogHead(mood: store.mood, size: 36).padding(.top, 9).padding(.bottom, 5)
            ForEach(store.tasks.prefix(9)) { t in RailIcon(task: t, store: store) }
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { store.layout = "card" }
            } label: {
                Image(systemName: "rectangle.inset.topright.filled")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(store.railOpen ? 0.6 : 0.3))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to the full card")
            .padding(.top, 2).padding(.bottom, 8)
        }
        .frame(width: 52)
        .boardGlass(radius: 26, mood: store.mood)
    }

    var peek: some View {
        VStack(spacing: 0) {
            ForEach(store.tasks.prefix(9)) { t in Row(task: t, store: store) }
        }
        .frame(width: Rail.drawerWidth)
        .boardGlass(radius: 14, mood: store.mood)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { store.drawerSize = $0 }
        .padding(.top, 50) // rows line up with the rail's icons
    }

    var headline: String {
        switch store.mood {
        case .asking: return "Awaiting approval"
        case .ready: return "\(store.ready) ready for review"
        case .cooking: return "\(store.cooking) in progress"
        case .sleeping: return "All clear"
        }
    }
}

struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    let store = Store()
    var size = CGSize(width: 420, height: 160)
    var animating = false
    var dragStart: (mouse: NSPoint, origin: NSPoint)?
    var lastOverRail = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false // we drag it ourselves (see drag(_:))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)

        store.onResize = { [weak self] s in DispatchQueue.main.async { self?.resize(to: s) } }
        let root = Board(store: store)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        panel.contentView = NSHostingView(rootView: root)

        if !panel.setFrameUsingName("AgentBoard2"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 420, y: screen.maxY - 4))
        }
        panel.setFrameAutosaveName("AgentBoard2")
        panel.orderFrontRegardless()

        store.onDismiss = { [weak self] in self?.hide() }
        store.onDrag = { [weak self] active in self?.drag(active) }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.trackRailMouse() }
        store.onLayoutChange = { [weak self] _ in
            DispatchQueue.main.async { guard let self else { return }; self.resize(to: self.size) }
        }
        store.onSummon = { [weak self] in self?.show() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Agent Board")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStatus() }
    }

    func updateStatus() {
        let n = store.ready + store.asking
        statusItem.button?.title = n > 0 ? " \(n)" : (store.cooking > 0 ? " …" : "")
    }

    @objc func toggle() { store.visible ? hide() : show() }

    /// Resize to content while keeping the top edge pinned.
    func screen(at p: NSPoint) -> NSRect? {
        (NSScreen.screens.first { $0.frame.contains(p) } ?? panel.screen ?? NSScreen.main)?.visibleFrame
    }

    /// Move the panel with the mouse; on release, a rail re-docks to the right edge of the screen it was dropped on.
    func drag(_ active: Bool) {
        let m = NSEvent.mouseLocation
        if active {
            if dragStart == nil { dragStart = (m, panel.frame.origin) }
            guard let d = dragStart else { return }
            panel.setFrameOrigin(NSPoint(x: d.origin.x + m.x - d.mouse.x, y: d.origin.y + m.y - d.mouse.y))
            return
        }
        dragStart = nil
        guard let sc = screen(at: m) else { return }
        var f = panel.frame
        if store.layout == "rail" { f.origin.x = sc.maxX - f.width - 4 }
        f.origin.x = max(sc.minX + 4, min(f.origin.x, sc.maxX - f.width - 4))
        f.origin.y = max(sc.minY + 4, min(f.origin.y, sc.maxY - f.height - 8))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().setFrame(f, display: true)
        }
    }

    /// Rail mode: open the drawer while the mouse is over the rail (or the open drawer), and let clicks
    /// pass through the reserved-but-empty drawer space so it never blocks the apps underneath.
    func trackRailMouse() {
        guard store.layout == "rail", store.visible else {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            if store.railOpen { store.railOpen = false }
            return
        }
        let m = NSEvent.mouseLocation, f = panel.frame
        let rs = store.railSize
        // drawer size from its known layout (measuring it races its own opening animation)
        let ds = CGSize(width: Rail.drawerWidth, height: CGFloat(min(store.tasks.count, 9)) * 40)
        let rail = NSRect(x: f.maxX - 2 - rs.width, y: f.maxY - 2 - rs.height, width: rs.width, height: rs.height)
        let drawer = NSRect(x: rail.minX - 8 - ds.width, y: f.maxY - 2 - 50 - ds.height, width: ds.width + 8, height: ds.height)
        let overRail = rail.contains(m)
        let overDrawer = store.railOpen && drawer.contains(m)
        if overRail || overDrawer || dragStart != nil {
            lastOverRail = Date()
            if overRail && !store.railOpen {
                jumpLog("rail drawer open (rail \(rs), drawer \(ds))")
                withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { store.railOpen = true }
                store.poke()
            }
        } else if store.railOpen && Date().timeIntervalSince(lastOverRail) > 0.35 {
            jumpLog("rail drawer close")
            withAnimation(.easeOut(duration: 0.2)) { store.railOpen = false }
        }
        let passThrough = !(overRail || overDrawer) && dragStart == nil
        if panel.ignoresMouseEvents != passThrough { panel.ignoresMouseEvents = passThrough }
    }

    func resize(to s: CGSize) {
        if FileManager.default.fileExists(atPath: boardDir.appendingPathComponent("debug").path),
           let h = FileHandle(forWritingAtPath: boardDir.appendingPathComponent("debug.log").path) ?? {
               FileManager.default.createFile(atPath: boardDir.appendingPathComponent("debug.log").path, contents: nil)
               return FileHandle(forWritingAtPath: boardDir.appendingPathComponent("debug.log").path) }() {
            h.seekToEndOfFile(); h.write("resize \(s) layout \(store.layout) frame \(panel.frame)\n".data(using: .utf8)!)
        }
        guard s.width > 0, s.height > 0 else { return }
        size = s
        guard !animating, dragStart == nil else { return }
        var f = panel.frame
        let top = f.maxY, right = f.maxX
        f.size = s
        f.origin.y = top - s.height
        f.origin.x = right - s.width
        // the screen under the board's top-left corner (panel.screen guesses wrong across two monitors,
        // and after a restart macOS restores the origin but not the size)
        let corner = NSPoint(x: panel.frame.minX + 1, y: top - 1)
        if let screen = screen(at: corner) {
            if store.layout == "rail" {
                // The rail always hugs the right edge of the screen, so its drawer opens to the left.
                f.origin.x = screen.maxX - s.width - 4
            } else {
                f.origin.x = max(screen.minX + 4, min(f.origin.x, screen.maxX - s.width - 4)) // stay on screen
            }
            f.origin.y = min(f.maxY, screen.maxY - 8) - s.height
        }
        panel.setFrame(f, display: true)
    }

    func show() {
        store.poke()
        guard !store.visible else { return }
        store.visible = true
        let target = panel.frame
        var start = target
        start.origin.y += 24
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.3, 0.4, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.animating = false
            self.resize(to: self.size)
        })
    }

    func hide() {
        guard store.visible else { return }
        let home = panel.frame
        var away = home
        away.origin.y += 20
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(away, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.setFrame(home, display: false)
            self.animating = false
            self.store.visible = false
        })
    }
}

// MARK: - Snapshot mode (renders previews so the design can be checked without a screen)

/// Desktop-style backdrop so the translucent board reads the way it does on screen.
struct Wallpaper<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(30)
            .background(
                ZStack {
                    LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.32), Color(red: 0.06, green: 0.20, blue: 0.36)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(Color(red: 0.55, green: 0.3, blue: 0.9).opacity(0.35)).frame(width: 260).blur(radius: 60).offset(x: -120, y: 60)
                }
            )
    }
}

@MainActor
func renderSnapshots(to dir: String) {
    let base = Date().timeIntervalSince1970
    func task(_ id: String, _ source: String, _ prompt: String, _ status: String, ago: Double, seen: Bool = false) -> AgentTask {
        AgentTask(id: id, ["source": source, "project": source == "claude" ? "my-app" : "website", "prompt": prompt,
                           "status": status, "seen": seen, "started": base - ago - 120, "finished": base - ago,
                           "updated": base - ago, "title": ["a": "Refactor Auth Flow", "b": "Fix Card Spacing", "c": "Add Unit Tests", "d": "Update API Docs", "e": "Run Database Migration"][id] ?? ""])
    }
    let scenes: [(String, [AgentTask])] = [
        ("cooking", [task("a", "claude", "Refactor the auth flow to use the new session tokens", "running", ago: 60),
                     task("b", "cursor", "Fix the match report card spacing", "running", ago: 200)]),
        ("ready", [task("c", "codex", "Add unit tests for the billing module", "done", ago: 90),
                   task("a", "claude", "Refactor the auth flow", "running", ago: 30),
                   task("d", "claude", "Update the API docs", "done", ago: 900, seen: true)]),
        ("asking", [task("e", "claude", "Run the database migration", "waiting", ago: 20)]),
        ("sleeping", []),
    ]
    for (name, tasks) in scenes {
        let store = Store(live: false)
        store.tasks = tasks
        store.now = Date(timeIntervalSince1970: base)
        for (name2, peek) in [("rail", false), ("rail-peek", true)] where name == "ready" {
            store.layout = "rail"
            let r = ImageRenderer(content: Wallpaper { Board(store: store, peekPreview: peek) }.environment(\.frozenTime, 1.37))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name2).png"))
            }
            store.layout = "card"
        }
        for (i, t) in [1.0, 1.37, 2.9].enumerated() {
            let r = ImageRenderer(content: Wallpaper { Board(store: store) }.environment(\.frozenTime, t))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(i).png"))
            }
        }
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { renderSnapshots(to: CommandLine.arguments[i + 1]) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
