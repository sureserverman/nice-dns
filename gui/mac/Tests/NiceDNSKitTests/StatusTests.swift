import XCTest
@testable import NiceDNSKit

/// gui/share/fixtures, found from this file: gui/mac/Tests/NiceDNSKitTests/.
func shareURL(_ parts: String...) -> URL {
    var u = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("share")
    for p in parts { u.appendPathComponent(p) }
    return u
}

func fixture(_ name: String) throws -> String {
    try String(contentsOf: shareURL("fixtures", name), encoding: .utf8)
}

final class StatusTests: XCTestCase {
    var installed = ""
    var notInstalled = ""
    var stale = ""
    var update = ""

    override func setUpWithError() throws {
        installed = try fixture("status-installed.tsv")
        notInstalled = try fixture("status-not-installed.tsv")
        stale = try fixture("status-stale.tsv")
        update = try fixture("status-update-available.tsv")
    }

    func testWrongSchemaIsRefused() {
        let text = installed.replacingOccurrences(of: statusSchema, with: "nice-dns-status/2")
        XCTAssertThrowsError(try Status.parse(text)) { e in
            XCTAssertEqual(e as? StatusParseError, .wrongSchema(found: "nice-dns-status/2"))
        }
        guard case .error(let m) = classify(exit: 0, stdout: text) else {
            return XCTFail("a wrong schema must be an error view")
        }
        XCTAssertTrue(m.contains("nice-dns-status/2"), m)
    }

    func testMissingSchemaLineIsRefused() {
        let text = installed.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        XCTAssertThrowsError(try Status.parse(text)) { e in
            XCTAssertEqual(e as? StatusParseError, .noSchema(found: "install\tinstalled\tyes"))
        }
        XCTAssertThrowsError(try Status.parse("")) { e in
            XCTAssertEqual(e as? StatusParseError, .noSchema(found: ""))
        }
    }

    func testInstalledFixtureParses() throws {
        let s = try Status.parse(installed)
        XCTAssertEqual(s.install.installed, true)
        XCTAssertEqual(s.install.generation, "20261109T180318Z-nogit0000000")
        XCTAssertEqual(s.install.variant, "socat")
        XCTAssertEqual(s.install.platform, "linux")
        XCTAssertEqual(s.controller.verdict, "OK")
        XCTAssertEqual(s.controller.stale, .no)
        XCTAssertEqual(s.controller.lastPass, .at(1794251828))
        XCTAssertEqual(s.obs.count, 15)
        XCTAssertEqual(s.obs[10], Obs(
            name: "route:cloudflare-onion", verdict: "healthy", ms: 1930,
            reason: "rcode NOERROR in 0 ms via tor-socat:18531 as tor.cloudflare-dns.com"))
        XCTAssertEqual(s.route, Route(id: "cloudflare-onion", generation: "73"))
        XCTAssertEqual(s.bridges.mode, "on")
        XCTAssertEqual(s.bridges.count, 7)
        XCTAssertEqual(s.bridges.lastRefresh, .never)
        XCTAssertEqual(s.update.result, .unknown)
        XCTAssertTrue(s.update.neverChecked)
        XCTAssertEqual(s.helper.version, "0.1.1")
        XCTAssertEqual(s.helper.installed, true)
        XCTAssertEqual(s.admin.url, "http://localhost:8880/admin")
        XCTAssertEqual(s.recent.count, 5)
        XCTAssertEqual(s.recent[4].epoch, 1794247806)
        XCTAssertEqual(s.recent[4].result, "ready")
        XCTAssertTrue(s.unreadable.isEmpty)
        XCTAssertEqual(classify(exit: 0, stdout: installed), .installed(s))
    }

    func testNotInstalledFixtureParses() throws {
        let s = try Status.parse(notInstalled)
        XCTAssertEqual(s.install.installed, false)
        XCTAssertNil(s.install.generation)
        XCTAssertTrue(s.obs.isEmpty)
        let hint = try XCTUnwrap(s.install.hint)
        XCTAssertTrue(hint.hasPrefix("curl -fsSL https://raw.githubusercontent.com/sureserverman/nice-dns/main/install-deb.sh"))
        XCTAssertEqual(classify(exit: 1, stdout: notInstalled), .notInstalled(hint: hint, unreadable: []))
        // Exit 2 with `installed no`: still not installed, with the unreadable rows.
        let both = notInstalled + "bridges\tunreadable\t~/x: permission denied\n"
        XCTAssertEqual(classify(exit: 2, stdout: both), .notInstalled(
            hint: hint, unreadable: [Unreadable(group: "bridges", reason: "~/x: permission denied")]))
    }

    func testStaleFixtureParses() throws {
        let s = try Status.parse(stale)
        XCTAssertEqual(s.install.generation, "20261109T180318Z-nogit0000000")
        XCTAssertEqual(s.controller.stale, .seconds(942))
        XCTAssertEqual(s.controller.verdict, "OK")
        XCTAssertEqual(s.obs.count, 15)
        XCTAssertEqual(classify(exit: 0, stdout: stale), .installed(s))
    }

    func testUpdateAvailableFixtureParses() throws {
        let s = try Status.parse(update)
        XCTAssertEqual(s.install.variant, "socat")
        XCTAssertEqual(s.update.result, .available)
        XCTAssertFalse(s.update.neverChecked)
        XCTAssertEqual(s.update.checkedAt, 1794251900)
        XCTAssertEqual(s.update.remoteCommit, "0f6a6e7c3d2b1a09f8e7d6c5b4a39281706f5e4d")
        XCTAssertEqual(s.helper.version, "0.1.1")
    }

    func testStaleValuesParseToTheEnum() {
        XCTAssertEqual(Stale.parse("no"), .no)
        XCTAssertEqual(Stale.parse("942"), .seconds(942))
        XCTAssertEqual(Stale.parse("never"), .never)
        XCTAssertEqual(Stale.parse("future"), .future)
        XCTAssertNil(Stale.parse("soon"))
    }

    func testUnknownGroupAndKeyAreIgnored() throws {
        let text = installed + "newgroup\tthing\tvalue\ninstall\tnewkey\tvalue\nbridges\tcolour\tblue\n"
        XCTAssertEqual(try Status.parse(text), try Status.parse(installed))
    }

    func testUnreadableRowIsKept() throws {
        let text = installed.replacingOccurrences(
            of: "bridges\tcount\t7\n",
            with: "bridges\tunreadable\t~/.config/nice-dns/bridges.env: permission denied\n")
        let s = try Status.parse(text)
        XCTAssertNil(s.bridges.count)
        XCTAssertEqual(s.unreadable(in: "bridges"), ["~/.config/nice-dns/bridges.env: permission denied"])
        XCTAssertEqual(s.unreadable(in: "install"), [])
        XCTAssertEqual(classify(exit: 2, stdout: text), .unreadable(s))
    }

    func testExitCodesMapToViews() {
        XCTAssertEqual(classify(exit: 2, stdout: ""), .error("status exited 2 with nothing on stdout"))
        XCTAssertEqual(classify(exit: 3, stdout: installed), .error("status exited 3"))
        guard case .error = classify(exit: nil, stdout: installed) else { return XCTFail("signal") }
        guard case .error = classify(exit: 1, stdout: installed) else { return XCTFail("1 with installed") }
        guard case .error = classify(exit: 0, stdout: notInstalled) else { return XCTFail("0 with not installed") }
    }
}
