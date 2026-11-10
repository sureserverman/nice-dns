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

print("KitCheck: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
