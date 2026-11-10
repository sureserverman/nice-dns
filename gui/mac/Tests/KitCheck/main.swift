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

try? FileManager.default.removeItem(atPath: emptyHome)

print("KitCheck: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
