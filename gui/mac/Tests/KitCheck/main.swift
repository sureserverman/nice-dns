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
if case .installed(var s) = view("status-installed.tsv", 0) {
    s.obs[0].verdict = "unhealthy"
    check("an unhealthy observation makes the glyph red", Glyph.of(.installed(s)) == .red)
    s.obs[0].verdict = "indeterminate"
    check("an indeterminate observation makes the glyph amber", Glyph.of(.installed(s)) == .amber)
}

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

let tail = " The stack is reinstalled from the kept source. This takes a few minutes and DNS stops briefly."
for (id, head) in [("proxy-haproxy", "Switch the proxy to haproxy?"), ("proxy-socat", "Switch the proxy to socat?"),
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

try? FileManager.default.removeItem(atPath: emptyHome)

print("KitCheck: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
