// KitCheck: the portable verifier of NiceDNSKit (Command Line Tools ship no
// XCTest). Run from gui/mac: `swift run KitCheck [<gui/share dir>]`.
// It parses every status fixture, refuses a wrong schema, and checks that the
// action table bundled in the kit equals gui/share/actions.tsv row for row.
// Exit 0 when every check passes, 1 otherwise.
import Foundation
import NiceDNSKit

var passed = 0
var failed = 0

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
        print("ok   \(name)")
    } else {
        failed += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : ": \(d)"))
    }
}

let args = CommandLine.arguments.dropFirst()
let share = URL(fileURLWithPath: args.first ?? "../share", isDirectory: true).standardizedFileURL
let fixtures = share.appendingPathComponent("fixtures", isDirectory: true)

// --- Status fixtures ---------------------------------------------------------

/// The exit code `nice-dns status --tsv` gives with each fixture.
let expectedExit: [String: Int32] = [
    "status-installed.tsv": 0,
    "status-not-installed.tsv": 1,
    "status-stale.tsv": 0,
    "status-update-available.tsv": 0,
]

let names = ((try? FileManager.default.contentsOfDirectory(atPath: fixtures.path)) ?? [])
    .filter { $0.hasSuffix(".tsv") }
    .sorted()
check("fixtures found in \(fixtures.path)", !names.isEmpty, "no *.tsv")
for known in expectedExit.keys.sorted() {
    check("fixture \(known) is there", names.contains(known))
}

for name in names {
    guard let text = try? String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8) else {
        check("fixture \(name) reads", false)
        continue
    }
    let status: Status
    do {
        status = try Status.parse(text)
        check("fixture \(name) parses", true)
    } catch {
        check("fixture \(name) parses", false, "\(error)")
        continue
    }
    let code = expectedExit[name] ?? (status.install.installed == false ? 1 : 0)
    switch classify(exit: code, stdout: text) {
    case .installed:
        check("fixture \(name) is an installed stack", status.install.installed == true)
    case .notInstalled(let hint, _):
        check("fixture \(name) is not installed, with the hint", status.install.installed == false && hint != nil)
    case let other:
        check("fixture \(name) classifies with exit \(code)", false, "\(other)")
    }
    switch name {
    case "status-stale.tsv":
        check("fixture \(name) says stale 942", status.controller.stale == .seconds(942), "\(String(describing: status.controller.stale))")
    case "status-update-available.tsv":
        check("fixture \(name) says update available", status.update.result == .available)
    case "status-installed.tsv":
        check("fixture \(name) has 15 obs and 5 recent", status.obs.count == 15 && status.recent.count == 5,
              "\(status.obs.count) obs, \(status.recent.count) recent")
    default:
        break
    }

    // The same rows under another schema must be refused.
    var lines = text.components(separatedBy: "\n")
    lines[0] = "schema\tnice-dns-status/2"
    let wrong = lines.joined(separator: "\n")
    do {
        _ = try Status.parse(wrong)
        check("fixture \(name) under schema nice-dns-status/2 is refused", false, "it was accepted")
    } catch let e as StatusParseError {
        check("fixture \(name) under schema nice-dns-status/2 is refused",
              e == .wrongSchema(found: "nice-dns-status/2"), "\(e)")
    } catch {
        check("fixture \(name) under schema nice-dns-status/2 is refused", false, "\(error)")
    }
    if case .error(let m) = classify(exit: code, stdout: wrong) {
        check("fixture \(name) under schema nice-dns-status/2 is an error view", m.contains("nice-dns-status/2"), m)
    } else {
        check("fixture \(name) under schema nice-dns-status/2 is an error view", false, "it was shown")
    }
}

do {
    _ = try Status.parse("install\tinstalled\tyes\n")
    check("a status without a schema line is refused", false, "it was accepted")
} catch {
    check("a status without a schema line is refused",
          (error as? StatusParseError) == .noSchema(found: "install\tinstalled\tyes"), "\(error)")
}
do {
    _ = try Status.parse("")
    check("an empty status is refused", false, "it was accepted")
} catch {
    check("an empty status is refused", (error as? StatusParseError) == .noSchema(found: ""), "\(error)")
}

// --- The action table ------------------------------------------------------

let sharedTable = share.appendingPathComponent("actions.tsv")
do {
    let bundled = try Actions.bundledText()
    let shared = try String(contentsOf: sharedTable, encoding: .utf8)
    let b = bundled.components(separatedBy: "\n")
    let s = shared.components(separatedBy: "\n")
    var drift: [String] = []
    for i in 0..<max(b.count, s.count) {
        let bl = i < b.count ? b[i] : "<none>"
        let sl = i < s.count ? s[i] : "<none>"
        if bl != sl {
            drift.append("row \(i + 1): bundled '\(bl)', \(sharedTable.path) '\(sl)'")
        }
    }
    check("the bundled action table equals \(sharedTable.path) row for row",
          drift.isEmpty && bundled == shared, drift.joined(separator: "; "))
    do {
        let bundledActions = try Actions.loadBundled()
        let sharedActions = try Actions.parse(shared)
        check("the bundled action table parses (\(bundledActions.count) actions)", !bundledActions.isEmpty)
        check("the bundled actions equal the shared actions", bundledActions == sharedActions)
    } catch {
        check("the action tables parse", false, "\(error)")
    }
} catch {
    check("the bundled and shared action tables read", false, "\(error)")
}

// --- What the window and the hooks share (Task 1.2) ------------------------

check("exit 126 says authorisation cancelled",
      outcome(id: "restart", end: .exit(.code(126)), lines: []) == "authorisation cancelled (exit 126)")
check("a failure that printed lib/root.sh's line says authorisation cancelled",
      outcome(id: "restart", end: .exit(.code(1)), lines: ["nice-dns: authorisation cancelled"]) == "authorisation cancelled (exit 1)")
check("update-check exit 10 says a different version is available (DEC-023)",
      outcome(id: "update-check", end: .exit(.code(10)), lines: []) == "a different version is available (exit 10)")
check("exit 0 says finished", outcome(id: "restart", end: .exit(.code(0)), lines: []) == "finished (exit 0)")
check("update-check 10 and update 11 count as success, other non-zero exits do not",
      succeeded(id: "update-check", end: .exit(.code(10))) && succeeded(id: "update", end: .exit(.code(11)))
      && !succeeded(id: "restart", end: .exit(.code(10))) && !succeeded(id: "restart", end: .exit(.code(1))))

func view(_ fixture: String, _ code: Int32) -> StatusView {
    let text = (try? String(contentsOf: fixtures.appendingPathComponent(fixture), encoding: .utf8)) ?? ""
    return classify(exit: code, stdout: text)
}
for (fixture, code, glyph) in [("status-installed.tsv", Int32(0), Glyph.green), ("status-stale.tsv", 0, .amber),
                               ("status-update-available.tsv", 0, .green), ("status-not-installed.tsv", 1, .grey)] {
    let g = Glyph.of(view(fixture, code))
    check("the glyph for \(fixture) is \(glyph)", g == glyph, "it is \(g)")
}
check("the glyph for a status that cannot be shown is red", Glyph.of(.error("status exited 3")) == .red)

let fakebin = fixtures.appendingPathComponent("fakebin").path
let emptyHome = FileManager.default.temporaryDirectory.appendingPathComponent("kitcheck-home-\(getpid())").path
try? FileManager.default.createDirectory(atPath: emptyHome, withIntermediateDirectories: true)
let fakeEnv = ["PATH": "\(fakebin):/usr/bin:/bin", "HOME": emptyHome]
let bareEnv = ["PATH": "/usr/bin:/bin", "HOME": emptyHome]

check("nice-dns is found on PATH first",
      (try? CommandPaths.resolve("nice-dns", environment: fakeEnv)) == "\(fakebin)/nice-dns")
do {
    _ = try CommandPaths.resolve("nice-dns", environment: bareEnv)
    check("a missing nice-dns names ~/.local/bin/nice-dns", false, "it was found")
} catch let nf as CommandNotFound {
    check("a missing nice-dns names ~/.local/bin/nice-dns", nf.path == "\(emptyHome)/.local/bin/nice-dns", nf.path)
} catch {
    check("a missing nice-dns names ~/.local/bin/nice-dns", false, "\(error)")
}
check("the commands' PATH gains ~/.local/bin and /opt/homebrew/bin",
      CommandPaths.childEnvironment(bareEnv)["PATH"] == "/usr/bin:/bin:\(emptyHome)/.local/bin:/opt/homebrew/bin:/usr/local/bin")

let fakeStatus = fixtures.appendingPathComponent("fake-status.sh").path
let installedFixture = fixtures.appendingPathComponent("status-installed.tsv").path
let (c0, l0) = statusCheck(environment: bareEnv.merging(["NICE_DNS_GUI_STATUS_CMD": "\(fakeStatus) \(installedFixture) 0"]) { $1 })
check("--check on an installed stack exits 0 naming the generation",
      c0 == 0 && l0 == "installed: generation 20261109T180318Z-nogit0000000; controller OK, fresh", "\(c0) \(l0)")
let (c1, l1) = statusCheck(environment: bareEnv)
check("--check with nice-dns missing exits 1 naming the path",
      c1 == 1 && l1 == "nice-dns command not found: looked for \(emptyHome)/.local/bin/nice-dns", "\(c1) \(l1)")

/// Run action `id` through ActionRun against the fake nice-dns; what it
/// recorded, and the run.
func runFake(_ id: String, exit code: Int32 = 0, choices: Choices? = nil) -> (recorded: String, run: ActionRun) {
    let record = FileManager.default.temporaryDirectory.appendingPathComponent("kitcheck-record-\(getpid())-\(id)").path
    try? FileManager.default.removeItem(atPath: record)
    let env = fakeEnv.merging(["NICE_DNS_FAKE_RECORD": record, "NICE_DNS_FAKE_EXIT": "\(code)"]) { $1 }
    let run = ActionRun(id: id)
    let done = DispatchSemaphore(value: 0)
    run.start(choices: choices, environment: env, queue: DispatchQueue(label: "kitcheck.run")) { r in
        if r.end != nil { done.signal() }
    }
    if done.wait(timeout: .now() + 30) == .timedOut { return ("<timed out>", run) }
    let recorded = (try? String(contentsOfFile: record, encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(atPath: record)
    return (recorded.trimmingCharacters(in: .newlines), run)
}
for (id, words) in [("restart", "restart"), ("bridges-off", "bridges off"), ("bridges-on", "bridges on"),
                    ("update-check", "update --check"), ("uninstall", "uninstall")] {
    let (rec, run) = runFake(id)
    check("action \(id) runs `nice-dns \(words)` and exits 0", rec == words && run.exitStatus == 0, "recorded '\(rec)', exit \(run.exitStatus)")
}
let (recR, _) = runFake("reinstall", choices: Choices(variant: "socat", pihole: "standard", branch: "main"))
check("reinstall passes its choices", recR == "reinstall socat --standard --branch main", recR)
let (_, cancelled) = runFake("restart", exit: 126)
check("a dismissed authorisation keeps the output and says authorisation cancelled",
      cancelled.exitStatus == 126 && cancelled.paneText.contains("fake nice-dns: restart")
      && cancelled.paneText.hasSuffix("authorisation cancelled (exit 126)\n"), cancelled.paneText)
let (_, failedRun) = runFake("restart", exit: 3)
check("a failed action keeps its output and its exit",
      failedRun.paneText.hasPrefix("$ \(fakebin)/nice-dns restart\n") && failedRun.paneText.contains("a line on stderr")
      && failedRun.said == "failed (exit 3)" && failedRun.exitStatus == 3, failedRun.paneText)

// --- Stage 1 gate round 1 -------------------------------------------------

// A command that leaves a process behind holding its output: the exit comes
// within the drain, last, and the late line is never delivered after it.
do {
    var events: [CommandEvent] = []
    let lock = NSLock()
    let started = Date()
    var exitAfter: TimeInterval?
    let done = DispatchSemaphore(value: 0)
    try CommandRunner.spawn(["/bin/sh", "-c", "echo first; (sleep 3; echo late) & exit 0"]) { ev in
        lock.lock()
        events.append(ev)
        if case .exit = ev { exitAfter = Date().timeIntervalSince(started); done.signal() }
        lock.unlock()
    }
    _ = done.wait(timeout: .now() + 10)
    Thread.sleep(forTimeInterval: 4)  // the left-behind process writes `late` now
    lock.lock()
    let seen = events
    let after = exitAfter
    lock.unlock()
    let lastIsExit: Bool = { if case .exit(.code(0))? = seen.last { return true }; return false }()
    check("a left-behind process holding the pipe does not hold the exit",
          (after ?? 99) < 2.5, "exit after \(after.map { "\($0)" } ?? "never") s")
    check("the exit stays the last event when a line comes after it",
          lastIsExit && seen.first == .line(.stdout, "first") && !seen.contains(.line(.stdout, "late")), "\(seen)")
} catch {
    check("a left-behind process holding the pipe does not hold the exit", false, "\(error)")
}

// Where the installer puts the command when PATH does not have it.
let instHome = FileManager.default.temporaryDirectory.appendingPathComponent("kitcheck-inst-\(getpid())").path
func plant(_ path: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
}
// On macOS the installer's fallback is ~/Library/Logs/nice-dns-health/bin
// (lib/install.sh _nd_inst_command_fallback_dir), not the Linux one.
plant("\(instHome)/.local/state/nice-dns-health/bin/nice-dns")
plant("\(instHome)/xdg/nice-dns-health/bin/nice-dns")
check("the Linux fallback is not where a Mac install puts the command",
      (try? CommandPaths.resolve("nice-dns", environment: ["PATH": "/usr/bin:/bin", "HOME": instHome, "XDG_STATE_HOME": "\(instHome)/xdg"])) == nil)
plant("\(instHome)/Library/Logs/nice-dns-health/bin/nice-dns")
check("nice-dns falls back to ~/Library/Logs/nice-dns-health/bin",
      (try? CommandPaths.resolve("nice-dns", environment: ["PATH": "/usr/bin:/bin", "HOME": instHome, "XDG_STATE_HOME": "\(instHome)/xdg"])) == "\(instHome)/Library/Logs/nice-dns-health/bin/nice-dns")
plant("\(instHome)/.local/bin/nice-dns")
check("~/.local/bin wins over the fallback",
      (try? CommandPaths.resolve("nice-dns", environment: ["PATH": "/usr/bin:/bin", "HOME": instHome])) == "\(instHome)/.local/bin/nice-dns")
try? FileManager.default.removeItem(atPath: instHome)

// An uninstall removes the bundle under a running app (Stage 2 gate round 1):
// it quits once its program has been gone on two ticks running and no action
// runs, so a reinstall's rename window or an uninstall run from the app does
// not end it.
do {
    var w = BundleWatch()
    check("a present program keeps the app", w.tick(programExists: true, busy: false) == false)
    check("one tick without the program is not enough", w.tick(programExists: false, busy: false) == false)
    check("two ticks without it quit the app", w.tick(programExists: false, busy: false) == true)
    var b = BundleWatch()
    _ = b.tick(programExists: false, busy: true)
    check("never while an action runs", b.tick(programExists: false, busy: true) == false)
    check("and once the action ended, after two ticks", b.tick(programExists: false, busy: false) == false && b.tick(programExists: false, busy: false) == true)
    var r = BundleWatch()
    _ = r.tick(programExists: false, busy: false)
    _ = r.tick(programExists: true, busy: false)
    check("a program back in place starts the count again", r.tick(programExists: false, busy: false) == false)
}

// The glyph: a stale controller is amber even over an old FAIL; a missing
// `stale` row is not stale.
if case .installed(var s) = view("status-stale.tsv", 0) {
    s.obs[0].verdict = "unhealthy"
    s.controller.verdict = "FAIL [unbound]"
    check("a stale controller is amber even when its old verdict is FAIL", Glyph.of(.installed(s)) == .amber, "\(Glyph.of(.installed(s)))")
}
if case .installed(var s) = view("status-installed.tsv", 0) {
    s.controller.stale = nil
    check("a missing stale row is not read as stale", Glyph.of(.installed(s)) == .green, "\(Glyph.of(.installed(s)))")
}

// --- The selectors and where each action is drawn (Task 2.2) ---------------

// Every row of the WHOLE bundled table has exactly one place; a row added to
// the table and to no place, or to two, fails here.
do {
    let table = try Actions.loadBundled()
    for a in table {
        let p = Placement.places(of: a.id)
        check("action \(a.id) has exactly one place", p.count == 1,
              p.isEmpty ? "no place draws it" : "drawn as \(p.map(\.description).joined(separator: " and "))")
    }
    check("every place names only rows of the table", Placement.undeclaredRows(in: table).isEmpty,
          Placement.undeclaredRows(in: table).joined(separator: ", "))
    let added = try Actions.parse(try Actions.bundledText() + "new-thing\tA new thing\tnice-dns new\tno\tyes\n")
    let forgotten = Placement.misplaced(in: added)
    check("a row added to the table and to no place is caught",
          forgotten.count == 1 && forgotten[0].id == "new-thing" && forgotten[0].places.isEmpty, "\(forgotten)")
    check("the bundled table has no misplaced row", Placement.misplaced(in: table).isEmpty, "\(Placement.misplaced(in: table))")
} catch {
    check("the bundled action table reads for the places", false, "\(error)")
}

// The views draw an action only through Placement (its button list and its
// named ids) or StackChoice, never through a string literal at a drawing
// call: a literal there would draw a place `declared` does not know, and the
// every-row check above would pass over it.
do {
    let gui = share.deletingLastPathComponent().appendingPathComponent("mac/Sources/NiceDNSGUI", isDirectory: true)
    let drawing = try NSRegularExpression(pattern: #"(request\("|entry\([^\n]*, "[a-z-]+"\)|lookup\(")"#)
    var found: [String] = []
    for f in ["WindowView.swift", "MenuBar.swift"] {
        let text = try String(contentsOf: gui.appendingPathComponent(f), encoding: .utf8)
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            let r = NSRange(line.startIndex..., in: line)
            if drawing.firstMatch(in: line, range: r) != nil { found.append("\(f):\(n + 1)") }
        }
    }
    check("the views name no action id as a literal at a drawing call", found.isEmpty, found.joined(separator: ", "))
} catch {
    check("the view sources read for the drawing calls", false, "\(error)")
}

let buttonIds = Placement.buttons().map(\.id)
for id in ["proxy-haproxy", "proxy-socat", "pihole-standard", "pihole-hardened"] {
    check("\(id) is not a plain button", !buttonIds.contains(id), buttonIds.joined(separator: " "))
    check("\(id) is a selector's choice", Placement.place(of: id) == .selector)
}
check("the plain buttons are the table's plain rows, in table order",
      buttonIds == ["reinstall", "restart", "uninstall", "update-check", "health-start", "health-stop", "health-run", "failures"],
      buttonIds.joined(separator: " "))
check("the update is the banner's, the bridges the switch's, install the not-installed page's",
      Placement.place(of: "update") == .updateBanner && Placement.place(of: "bridges-on") == .bridgesSwitch
      && Placement.place(of: "bridges-off") == .bridgesSwitch && Placement.place(of: "install") == .installView)

let tail = " The stack is rebuilt from the kept source. This takes a few minutes and DNS stops briefly. The running stack stays if anything fails."
for (id, head) in [("proxy-haproxy", "Switch the Tor proxy to haproxy?"), ("proxy-socat", "Switch the Tor proxy to socat?"),
                   ("pihole-standard", "Switch Pi-hole to standard?"), ("pihole-hardened", "Switch Pi-hole to hardened?")] {
    let q = StackChoice.question(for: id)
    check("the question for \(id) is \"\(head)...\"", q == head + tail, q ?? "none")
}
check("no question for an action that is not a choice", StackChoice.question(for: "restart") == nil)

// The pending choice of each selector: set when the switch runs, kept
// through the run and its end, cleared by the first read after the end,
// reverted at once on a failed exit, and a dismissed question goes back.
if case .installed(let installedStatus) = view("status-installed.tsv", 0) {
    for (sel, other) in [(StackChoice.proxy, "haproxy"), (StackChoice.pihole, "hardened")] {
        let was = sel.installed(in: installedStatus)
        check("\(sel.title) shows the status' value \(was ?? "none")",
              was == (sel.kind == .proxy ? "socat" : "standard") && SwitchState().shown(sel, status: installedStatus) == was)
        var s = SwitchState()
        s.ask(sel.id(other))
        check("\(sel.title) shows \(other) while the question is asked", s.shown(sel, status: installedStatus) == other)
        s.dismiss()
        check("\(sel.title) goes back to \(was ?? "none") on Not now", s.shown(sel, status: installedStatus) == was && s.pending.isEmpty)
        s.ask(sel.id(other))
        s.started(sel.id(other))
        check("\(sel.title) pending is set to \(other) when the switch runs",
              s.pending[sel.kind] == other && s.shown(sel, status: installedStatus) == other)
        s.statusRead()
        check("\(sel.title) keeps \(other) through a read while it runs", s.shown(sel, status: installedStatus) == other)
        s.ended(sel.id(other), succeeded: true)
        check("\(sel.title) keeps \(other) after it ended, before the read", s.shown(sel, status: installedStatus) == other)
        var after = installedStatus
        if sel.kind == .proxy { after.install.variant = other } else { after.install.pihole = other }
        s.statusRead()
        check("\(sel.title) pending is cleared by the first read after the end",
              s.pending[sel.kind] == nil && s.shown(sel, status: after) == other && s.shown(sel, status: installedStatus) == was)
        var f = SwitchState()
        f.ask(sel.id(other))
        f.started(sel.id(other))
        f.ended(sel.id(other), succeeded: false)
        check("\(sel.title) pending is reverted on a failed exit, before any read",
              f.pending[sel.kind] == nil && f.shown(sel, status: installedStatus) == was)
        var o = SwitchState()
        o.started("restart")
        o.ended("restart", succeeded: true)
        o.statusRead()
        check("\(sel.title) is untouched by another action", o.pending.isEmpty && o.shown(sel, status: installedStatus) == was)
    }
    for (sel, bad) in [(StackChoice.proxy, "tor"), (StackChoice.pihole, "extra")] {
        var none = installedStatus
        var odd = installedStatus
        if sel.kind == .proxy { none.install.variant = nil; odd.install.variant = bad } else { none.install.pihole = nil; odd.install.pihole = bad }
        check("\(sel.title) is unknown when the status names no value", SwitchState().shown(sel, status: none) == nil)
        check("\(sel.title) is unknown when the status names \(bad)", SwitchState().shown(sel, status: odd) == nil)
        let other = sel.kind == .proxy ? StackChoice.pihole : StackChoice.proxy
        check("\(other.title) still shows its value then", SwitchState().shown(other, status: none) != nil)
    }
    check("no selector value without a status", SwitchState().shown(.proxy, status: nil) == nil)
} else {
    check("status-installed.tsv is an installed stack for the selectors", false)
}

// The four switches run their command; a failure keeps stderr and names the exit.
for (id, words) in [("proxy-haproxy", "switch proxy haproxy"), ("proxy-socat", "switch proxy socat"),
                    ("pihole-standard", "switch pihole standard"), ("pihole-hardened", "switch pihole hardened")] {
    let (rec, run) = runFake(id)
    check("action \(id) runs `nice-dns \(words)` and exits 0",
          rec == words && run.exitStatus == 0 && run.paneText.contains("Switched: ") && succeeded(id: id, end: run.end!),
          "recorded '\(rec)', exit \(run.exitStatus)")
}
let (_, sw3) = runFake("proxy-socat", exit: 3)
check("a switch that exits 3 keeps stderr and says failed (exit 3)",
      sw3.paneText.contains("a line on stderr") && sw3.said == "failed (exit 3)" && !succeeded(id: "proxy-socat", end: sw3.end!), sw3.paneText)
check("its notice says the switch did not happen",
      StackChoice.failedNotice(for: "proxy-socat", said: sw3.said ?? "") == "The switch did not happen: failed (exit 3); the proxy is unchanged")
let (_, sw126) = runFake("pihole-hardened", exit: 126)
check("a switch whose root step was not authorised says authorisation cancelled (exit 126)",
      sw126.paneText.contains("a line on stderr") && sw126.said == "authorisation cancelled (exit 126)", sw126.paneText)
check("its notice says the switch did not happen",
      StackChoice.failedNotice(for: "pihole-hardened", said: sw126.said ?? "") == "The switch did not happen: authorisation cancelled (exit 126); Pi-hole is unchanged")
check("no switch notice for another action", StackChoice.failedNotice(for: "restart", said: "failed (exit 1)") == nil)

// The Update row says when the last check ran, whoever ran it.
check("ago says just now, minutes, hours, days and the future",
      ago(995, now: 1000) == "just now" && ago(700, now: 1000) == "5 min ago" && ago(0, now: 7200) == "2 h ago"
      && ago(0, now: 3 * 86_400) == "3 days ago" && ago(1010, now: 1000) == "in the future")
if case .installed(let u) = view("status-update-available.tsv", 0), case .installed(let n) = view("status-installed.tsv", 0) {
    check("the Update row names the answer and when it was checked",
          updateRow(u.update, now: 1794251900 + 600) == "available: 0f6a6e7c3d2b (checked 10 min ago)", updateRow(u.update, now: 1794251900 + 600))
    var later = u.update
    later.checkedAt = 1794251900 + 590
    later.result = .current
    check("the Update row moves when a later check (the schedule's) wrote checked_at",
          updateRow(later, now: 1794251900 + 600) == "up to date (checked just now)", updateRow(later, now: 1794251900 + 600))
    check("the Update row says not checked yet without a check", updateRow(n.update, now: 1794251900) == "not checked yet", updateRow(n.update, now: 1794251900))
}

// --- The status level, the check table and what the views say (GUI spec 3 to 7) ---

func fixtureStatus(_ name: String) -> Status {
    let text = (try? String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)) ?? ""
    return (try? Status.parse(text)) ?? (try! Status.parse("schema\t\(statusSchema)\n"))
}
func tweak(_ s: Status, _ f: (inout Status) -> Void) -> Status {
    var c = s
    f(&c)
    return c
}
func setVerdict(_ s: inout Status, _ name: String, _ verdict: String) {
    if let i = s.obs.firstIndex(where: { $0.name == name }) { s.obs[i].verdict = verdict }
}
let okStatus = fixtureStatus("status-installed.tsv")
let staleStatus = fixtureStatus("status-stale.tsv")
let updateStatus = fixtureStatus("status-update-available.tsv")
let passAt: UInt64 = 1794251828
let nowFresh = passAt + 12

// The shared check table and its bundled copy.
do {
    let bundled = try Checks.bundledText()
    let shared = try String(contentsOf: share.appendingPathComponent("checks.tsv"), encoding: .utf8)
    check("the bundled check table equals \(share.path)/checks.tsv", bundled == shared)
    let rows = try Checks.parse(shared)
    check("the check table parses (\(rows.count) rows, with the * row)", rows.count == 18 && rows.last?.id == Checks.other, "\(rows.count)")
    check("the bundled checks equal the shared checks", try Checks.loadBundled() == rows)
    check("every path node of the table is one of the five", rows.allSatisfy { ["", "computer", "pihole", "unbound", "tor", "resolver"].contains($0.pathNode) })
    check("every fixture's observation names resolve in the table",
          [okStatus, staleStatus, updateStatus].allSatisfy { $0.obs.allSatisfy { Checks.info($0.name) != nil } },
          (okStatus.obs.filter { Checks.info($0.name) == nil }).map(\.name).joined(separator: ", "))
    check("dns-owner is down and filtering is attention when unhealthy",
          Checks.info("dns-owner")?.levelWhenUnhealthy == .down && Checks.info("filtering")?.levelWhenUnhealthy == .attention)
    let raw = Checks.resolve("new-thing")
    check("a name not in the table gets the * row with its raw id",
          raw.id == "new-thing" && raw.name == "new-thing" && raw.group == "other" && raw.headline == "new-thing: check failed"
          && raw.levelWhenUnhealthy == .attention)
    func refused(_ t: String) -> Bool { (try? Checks.parse(t)) == nil }
    let header = shared.components(separatedBy: "\n")[0]
    check("a check table with no header, a short row, a bad level or no * row is refused",
          refused("a\tb\tc\n") && refused(shared.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
          && refused(header + "\nx\tg\tn\t\tbad\th\t\t\n") && refused(header + "\nx\tg\tn\t\tdown\th\t\t\n"))
} catch {
    check("the check tables read", false, "\(error)")
}

// The level, first match wins (spec section 3).
check("installed is ok", Level.of(okStatus) == .ok)
check("the stale fixture is stale", Level.of(staleStatus) == .stale)
check("the update fixture is ok", Level.of(updateStatus) == .ok)
check("not installed", Level.of(view("status-not-installed.tsv", 1)) == .notInstalled)
check("a status that cannot be read is error", Level.of(.error("status exited 3")) == .error)
check("stale never is waiting, even over a down check",
      Level.of(tweak(okStatus) { $0.controller.stale = Stale.never; setVerdict(&$0, "dns-owner", "unhealthy") }) == .waiting)
check("stale future is stale", Level.of(tweak(okStatus) { $0.controller.stale = Stale.future }) == .stale)
check("a stale pass is stale even over a down check",
      Level.of(tweak(staleStatus) { setVerdict(&$0, "dns-owner", "unhealthy") }) == .stale)
check("a missing stale row is not stale", Level.of(tweak(okStatus) { $0.controller.stale = nil }) == .ok)
let oneRouteDown = tweak(okStatus) {
    setVerdict(&$0, "route:cloudflare-onion", "unhealthy")
    $0.controller.verdict = "FAIL [route:cloudflare-onion]"
    $0.route = Route(id: "cloudflare-exit", generation: "74")
}
check("one failed backup route is attention, not down (D2)", Level.of(oneRouteDown) == .attention)
check("dns-owner unhealthy is down", Level.of(tweak(okStatus) { setVerdict(&$0, "dns-owner", "unhealthy") }) == .down)
for name in ["runtime", "container:pi-hole", "container:unbound", "container:tor-socat", "local-service", "unbound"] {
    check("\(name) unhealthy is down", Level.of(tweak(okStatus) { setVerdict(&$0, name, "unhealthy") }) == .down)
}
for name in ["filtering", "local-cache", "proxy", "install-drift"] {
    check("\(name) unhealthy is attention", Level.of(tweak(okStatus) { setVerdict(&$0, name, "unhealthy") }) == .attention)
}
check("every route unhealthy is down",
      Level.of(tweak(okStatus) { s in for n in s.obs.map(\.name) where n.hasPrefix("route:") { setVerdict(&s, n, "unhealthy") } }) == .down)
check("the verdict naming chain-resolves is down",
      Level.of(tweak(okStatus) { $0.controller.verdict = "FAIL [chain-resolves]" }) == .down)
check("chain-resolves after indeterminate= is not down",
      Level.of(tweak(okStatus) { $0.controller.verdict = "FAIL [route:quad9-exit] indeterminate=(chain-resolves)" }) == .attention)
check("an indeterminate check is attention", Level.of(tweak(okStatus) { setVerdict(&$0, "filtering", "indeterminate") }) == .attention)
check("a verdict that is not OK is attention", Level.of(tweak(okStatus) { $0.controller.verdict = "INDETERMINATE [filtering]" }) == .attention)
check("an unreadable row is attention",
      Level.of(tweak(okStatus) { $0.unreadable = [Unreadable(group: "bridges", reason: "~/x: permission denied")] }) == .attention)
check("an unknown name unhealthy is attention",
      Level.of(tweak(okStatus) { $0.obs.append(Obs(name: "new-thing", verdict: "unhealthy", ms: nil, reason: "r")) }) == .attention)
check("route-table unhealthy is down",
      Level.of(tweak(okStatus) { $0.obs.append(Obs(name: "route-table", verdict: "unhealthy", ms: nil, reason: "cannot read")) }) == .down)
check("the glyph colours: ok green, attention and stale amber, down and error red, waiting and not installed grey",
      Level.ok.glyph == .green && Level.attention.glyph == .amber && Level.stale.glyph == .amber
      && Level.down.glyph == .red && Level.error.glyph == .red && Level.waiting.glyph == .grey && Level.notInstalled.glyph == .grey)
check("the menu-bar symbols differ by level, so colour is not alone",
      Level.ok.menuSymbol == "checkmark.shield.fill" && Level.attention.menuSymbol == "exclamationmark.shield.fill"
      && Level.stale.menuSymbol == "exclamationmark.shield.fill" && Level.down.menuSymbol == "xmark.shield.fill"
      && Level.error.menuSymbol == "xmark.shield.fill" && Level.notInstalled.menuSymbol == "shield.slash"
      && Level.waiting.menuSymbol == "shield" && Level.loadingMenuSymbol == "shield")
check("the hero symbols", Level.ok.heroSymbol == "checkmark.shield" && Level.attention.heroSymbol == "exclamationmark.triangle"
      && Level.stale.heroSymbol == "exclamationmark.triangle" && Level.down.heroSymbol == "exclamationmark.shield"
      && Level.waiting.heroSymbol == "shield" && Level.notInstalled.heroSymbol == "shield")

// The hero's copy (spec section 3).
let heroOK = hero(okStatus, now: nowFresh)
check("the ok hero", heroOK.title == "DNS is protected" && heroOK.subtitle == "Every lookup leaves through Tor. Checked just now."
      && heroOK.action == .runChecks, "\(heroOK)")
let heroBackup = hero(oneRouteDown, now: nowFresh)
check("the backup-route hero", heroBackup.title == "DNS works, on a backup route"
      && heroBackup.subtitle == "The Cloudflare onion route is not answering. Lookups still leave through Tor.", "\(heroBackup)")
let heroAds = hero(tweak(okStatus) { setVerdict(&$0, "filtering", "unhealthy"); $0.controller.verdict = "FAIL [filtering]" }, now: nowFresh)
check("the ads-not-blocked hero", heroAds.title == "DNS works, but ads are not blocked"
      && heroAds.subtitle == "Lookups still leave through Tor. Checked just now.", "\(heroAds)")
let twoBad = tweak(okStatus) { setVerdict(&$0, "filtering", "unhealthy"); setVerdict(&$0, "local-cache", "unhealthy") }
check("the n-checks hero says 2 checks need attention", hero(twoBad, now: nowFresh).title == "DNS works, 2 checks need attention")
check("the n-checks hero says 1 check needs attention",
      hero(tweak(okStatus) { setVerdict(&$0, "local-cache", "unhealthy") }, now: nowFresh).title == "DNS works, 1 check needs attention")
let heroStale = hero(staleStatus, now: passAt + 942)
check("the stale hero says it in words, never stale 942s",
      heroStale.title == "Status is out of date" && heroStale.subtitle == "The last check ran 15 min ago. Checks are overdue."
      && heroStale.action == .runChecks && !"\(heroStale)".contains("stale 942"), "\(heroStale)")
let heroOff = hero(tweak(staleStatus) { $0.controller.schedule = "stopped" }, now: passAt + 942)
check("the schedule-stopped hero offers Turn On", heroOff.title == "Automatic checks are off"
      && heroOff.subtitle == "The last check ran 15 min ago." && heroOff.action == .turnOn, "\(heroOff)")
let heroWait = hero(tweak(okStatus) { $0.controller.stale = Stale.never }, now: nowFresh)
check("the waiting hero", heroWait.title == "Waiting for the first check" && heroWait.subtitle == "nice-dns has not checked this install yet.")
let heroOwner = hero(tweak(okStatus) { setVerdict(&$0, "dns-owner", "unhealthy") }, now: nowFresh)
check("dns-owner down names the check", heroOwner.title == "This computer is not using nice-dns"
      && heroOwner.subtitle == "/etc/resolv.conf: nameserver 127.0.0.1 only" && heroOwner.level == .down, "\(heroOwner)")
let allRoutesDown = tweak(okStatus) { s in for n in s.obs.map(\.name) where n.hasPrefix("route:") { setVerdict(&s, n, "unhealthy") } }
check("no route answers", hero(allRoutesDown, now: nowFresh).title == "DNS is down"
      && hero(allRoutesDown, now: nowFresh).subtitle == "No route through Tor is answering.")
check("another down check puts its headline in the subtitle",
      hero(tweak(okStatus) { setVerdict(&$0, "unbound", "unhealthy") }, now: nowFresh).subtitle == "Unbound is not answering")
check("a chain-resolves verdict alone still says DNS is down",
      hero(tweak(okStatus) { $0.controller.verdict = "FAIL [chain-resolves]" }, now: nowFresh).title == "DNS is down")
check("the hero of a not-installed view has no controller button",
      hero(view("status-not-installed.tsv", 1), now: nowFresh).action == nil)

// The lookup path (spec section 4.2).
let pathOK = lookupPath(okStatus)
check("the five nodes, captions and tones of an ok stack",
      pathOK.nodes.map(\.label) == ["This Mac", "Pi-hole", "Unbound", "Tor", "Cloudflare"]
      && pathOK.nodes.map(\.caption) == ["Asks", "Blocks ads", "Resolves", "7 bridges", "Onion resolver"]
      && pathOK.nodes.map(\.tone) == [.neutral, .ok, .ok, .ok, .ok]
      && pathOK.nodes.map(\.id) == PathNodeID.allCases, "\(pathOK.nodes)")
check("the footer names the seconds, the route and the backups",
      pathOK.footer == "Answered in 1.9 s on the Cloudflare onion route. 3 backup routes are ready.", pathOK.footer)
check("no node repeats the word healthy", !pathOK.sentence.contains("healthy"))
check("bridges off says No bridges", lookupPath(tweak(okStatus) { $0.bridges.mode = "off" }).nodes[3].caption == "No bridges")
let pathBackup = lookupPath(oneRouteDown)
check("a backup exit route: dashed line, attention colour, Backup: Tor exit",
      pathBackup.nodes[4].caption == "Backup: Tor exit" && pathBackup.nodes[4].tone == .attention
      && pathBackup.nodes[4].dashedIn && pathBackup.nodes[4].captionChanged && pathBackup.nodes[4].label == "Cloudflare"
      && pathBackup.nodes[0...3].allSatisfy { !$0.dashedIn }, "\(pathBackup.nodes[4])")
check("its footer counts the ready backups", pathBackup.footer == "Answered in 1.0 s on the Cloudflare Tor exit route. 2 backup routes are ready.", pathBackup.footer)
check("a failing container makes its node down",
      lookupPath(tweak(okStatus) { setVerdict(&$0, "container:pi-hole", "unhealthy") }).nodes[1].tone == .down)
check("a failing filtering check makes the Pi-hole node attention",
      lookupPath(tweak(okStatus) { setVerdict(&$0, "filtering", "unhealthy") }).nodes[1].tone == .attention)
check("dns-owner unhealthy makes the computer node down",
      lookupPath(tweak(okStatus) { setVerdict(&$0, "dns-owner", "unhealthy") }).nodes[0].tone == .down)
check("a stale status draws the path in neutral colours", lookupPath(staleStatus).nodes.allSatisfy { $0.tone == .neutral })
check("no route row says No route selected yet", lookupPath(tweak(okStatus) { $0.route = nil }).footer == "No route selected yet.")
let quad = lookupPath(tweak(okStatus) { $0.route = Route(id: "quad9-exit", generation: "1") })
check("a quad9 route names Quad9, via Tor exit", quad.nodes[4].label == "Quad9" && quad.nodes[4].caption == "Via Tor exit")
check("the panel's path line", pathLine(okStatus) == "Pi-hole › Unbound › Tor › Cloudflare onion", pathLine(okStatus))

// The attention list, Checks and the repairs.
check("an ok stack has no attention rows", attentionRows(okStatus).isEmpty)
let rowsBackup = attentionRows(oneRouteDown)
check("a failing route is one attention row with its headline and full reason",
      rowsBackup == [AttentionRow(id: "route:cloudflare-onion", tone: .attention, headline: "The Cloudflare onion route is not answering",
                                  reason: "rcode NOERROR in 0 ms via tor-socat:18531 as tor.cloudflare-dns.com")], "\(rowsBackup)")
check("a down row comes before an attention row",
      attentionRows(tweak(okStatus) { setVerdict(&$0, "filtering", "unhealthy"); setVerdict(&$0, "runtime", "unhealthy") }).map(\.id) == ["runtime", "filtering"])
check("the checks title counts", checksTitle(okStatus) == "15 of 15 checks passing" && checksTitle(twoBad) == "2 of 15 checks need attention")
let groupsOK = checkGroups(okStatus)
check("three groups, 5 + 6 + 4 passing, none expanded",
      groupsOK.map(\.id) == ["this-computer", "services", "routes"] && groupsOK.map(\.passing) == [5, 6, 4]
      && groupsOK.map(\.summary) == ["5 passing", "6 passing", "4 passing"] && groupsOK.allSatisfy { !$0.startsExpanded }, "\(groupsOK.map(\.summary))")
check("the services subtitle names the proxy", groupsOK[1].subtitle == "Pi-hole, Unbound, Tor proxy (socat), container runtime")
check("a route row shows seconds, and only the selected one is In use",
      groupsOK[2].rows.map(\.value) == ["1.9 s", "1.0 s", "0.9 s", "1.7 s"] && groupsOK[2].rows.map(\.inUse) == [true, false, false, false],
      "\(groupsOK[2].rows.map(\.value))")
check("a raw record is `{id} · {verdict} · {ms} ms` and the reason is whole",
      groupsOK[2].rows[0].record == "route:cloudflare-onion · healthy · 1930 ms"
      && groupsOK[2].rows[0].reason == "rcode NOERROR in 0 ms via tor-socat:18531 as tor.cloudflare-dns.com")
check("the runtime row says how many containers",
      groupsOK[1].rows.first { $0.id == "runtime" }?.value == "3 containers")
let groupsBad = checkGroups(oneRouteDown)
check("a group with a failing check starts expanded, says 1 failing and lists it first",
      groupsBad[2].startsExpanded && groupsBad[2].summary == "1 failing" && groupsBad[2].summaryTone == .attention
      && groupsBad[2].rows[0].id == "route:cloudflare-onion" && groupsBad[2].rows[0].headline == "The Cloudflare onion route is not answering"
      && !groupsBad[0].startsExpanded)
let groupsUnclear = checkGroups(tweak(okStatus) { setVerdict(&$0, "local-cache", "indeterminate") })
check("an indeterminate check says 1 unclear", groupsUnclear[0].summary == "1 unclear" && groupsUnclear[0].startsExpanded)
let groupsOther = checkGroups(tweak(okStatus) { $0.obs.append(Obs(name: "new-thing", verdict: "healthy", ms: nil, reason: "fine")) })
check("a name not in the table is under Other with its raw id",
      groupsOther.last?.id == "other" && groupsOther.last?.rows.first?.id == "new-thing" && groupsOther.last?.rows.first?.name == "new-thing")
check("no Other group when every name is known", !groupsOK.contains { $0.id == "other" })
let repairs = repairRows(okStatus, now: nowFresh)
check("the journal collapses to one line per target, newest first",
      repairs.map(\.text) == ["Moved back to the Cloudflare onion route", "Moved to the Cloudflare Tor exit route"], "\(repairs.map(\.text))")
check("a repair's time is an ago bucket", repairs.map(\.ago) == ["1 h ago", "1 h ago"], "\(repairs.map(\.ago))")
check("a step that is not ready says in progress",
      repairRows(tweak(okStatus) { $0.recent.removeLast() }, now: nowFresh).first?.text == "Moved back to the Cloudflare onion route (in progress)",
      "\(repairRows(tweak(okStatus) { $0.recent.removeLast() }, now: nowFresh).first?.text ?? "")")
let journal = tweak(okStatus) {
    $0.recent = [Recent(epoch: 10, target: "unbound", result: "ready"), Recent(epoch: 20, target: "pi-hole", result: "ready"),
                 Recent(epoch: 30, target: "tor-socat", result: "ready"), Recent(epoch: 40, target: "bridges", result: "ready"),
                 Recent(epoch: 50, target: "weird", result: "ready"), Recent(epoch: 60, target: "unbound", result: "ready")]
}
check("restarts name the container, bridges the mode, anything else the raw target, at most five lines",
      repairRows(journal, now: 100).map(\.text) == ["Restarted Unbound", "weird", "Bridges turned on", "Restarted Tor proxy (socat)", "Restarted Pi-hole"],
      "\(repairRows(journal, now: 100).map(\.text))")
check("the same target moved again after ready is a line of its own", repairRows(journal, now: 100).count == 5)
let links = overviewLinks(okStatus, now: nowFresh)
check("the links at level ok", links.passing == "15 of 15 checks passing"
      && links.repair == "Last repair 1 h ago · Moved back to the Cloudflare onion route", "\(links)")

// The update row, setup and the action bar.
check("update auto is parsed", okStatus.update.auto == "loaded")
check("an install never checked says Not checked yet",
      updateRowText(okStatus, now: nowFresh) == UpdateRowText(title: "Not checked yet", subtitle: nil, button: .check, commit: nil))
let avail = updateRowText(updateStatus, now: 1794251900 + 21 * 60)
check("an available update names the branch, the commit and when, and offers Install",
      avail == UpdateRowText(title: "Update available", subtitle: "Branch main is now at 0f6a6e7c3d2b, found 21 min ago.", button: .install, commit: "0f6a6e7c3d2b"), "\(avail)")
let currentRow = tweak(okStatus) { $0.update.result = .current; $0.update.neverChecked = false; $0.update.checkedAt = 1000 }
check("up to date keeps the twice-a-day sentence while auto is loaded",
      updateRowText(currentRow, now: 1600) == UpdateRowText(title: "Up to date", subtitle: "Branch main, checked 10 min ago. nice-dns checks twice a day.", button: .check, commit: nil))
check("and drops it when auto is stopped",
      updateRowText(tweak(currentRow) { $0.update.auto = "stopped" }, now: 1600).subtitle == "Branch main, checked 10 min ago.")
check("an unknown answer says Could not check, with when it was tried",
      updateRowText(tweak(okStatus) { $0.update.neverChecked = false; $0.update.checkedAt = 1000 }, now: 1600)
        == UpdateRowText(title: "Could not check for updates", subtitle: "Last tried 10 min ago.", button: .check, commit: nil))
check("the version row", versionRow(okStatus).title == "Installed 9 Nov 2026"
      && versionRow(okStatus).subtitle == "Branch main, source commit unknown"
      && versionRow(updateStatus).subtitle == "Branch main at 4b5432d1e0a9", "\(versionRow(okStatus))")
check("the build details carry the generation and the lock", buildDetails(okStatus).contains("generation: 20261109T180318Z-nogit0000000\n")
      && buildDetails(okStatus).contains("lock: sha256:90abe91") && buildDetails(okStatus).contains("helper: 0.1.1"))
check("the helper row only when it is missing", !helperMissing(okStatus) && helperMissing(tweak(okStatus) { $0.helper.installed = false }))
check("the admin row's URL has no scheme", adminSubtitle(okStatus) == "Blocklists and query log at localhost:8880/admin")
check("the automatic-checks switch follows the schedule", autoChecksOn(okStatus) && !autoChecksOn(tweak(okStatus) { $0.controller.schedule = "stopped" })
      && autoChecksSubtitle(tweak(okStatus) { $0.controller.mode = "shadow" }) == "Shadow mode: checks run, repairs do not.")
check("running titles are present tense", runningTitle("proxy-haproxy") == "Switching the Tor proxy to haproxy"
      && runningTitle("pihole-hardened") == "Switching Pi-hole to hardened" && runningTitle("restart") == "Restarting the stack")
check("result titles use the action's own last line where the contract has one",
      resultTitle("proxy-haproxy", lines: []) == "The Tor proxy is now haproxy"
      && resultTitle("bridges-on", lines: ["x", "Bridges are on; the proxy restarted and DNS is answering."]) == "Bridges are on; the proxy restarted and DNS is answering."
      && resultTitle("update", lines: ["updated to 0123456789ab"]) == "updated to 0123456789ab"
      && resultTitle("restart", lines: ["done"]) == "\(Actions.lookup("restart")?.label ?? "restart"): finished")
check("elapsed time", elapsedText(12) == "12 s" && elapsedText(192) == "3 min 12 s" && elapsedText(-1) == "0 s")
let paneRun = runFake("restart", exit: 3).run
check("each pane line has a kind: the command, stderr in its own, the outcome last",
      paneRun.paneKinds.count == paneRun.paneLines.count && paneRun.paneKinds.first == .command && paneRun.paneKinds.last == .outcome
      && paneRun.paneKinds.contains(.stderr) && paneRun.paneKinds.contains(.stdout), "\(paneRun.paneKinds)")
check("the dialog title and body of a switch (spec 9)",
      StackChoice.dialogTitle(for: "proxy-socat") == "Switch the Tor proxy to socat?"
      && StackChoice.pihole.dialogTitle("hardened") == "Switch Pi-hole to hardened?"
      && StackChoice.dialogBody.hasSuffix("The running stack stays if anything fails."))

try? FileManager.default.removeItem(atPath: emptyHome)

print("KitCheck: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
