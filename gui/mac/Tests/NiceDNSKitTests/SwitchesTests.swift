import XCTest
@testable import NiceDNSKit

final class SwitchesTests: XCTestCase {
    let choiceIds = ["proxy-haproxy", "proxy-socat", "pihole-standard", "pihole-hardened"]

    func installedStatus() throws -> Status {
        try Status.parse(try fixture("status-installed.tsv"))
    }

    func testEveryRowOfTheBundledTableHasExactlyOnePlace() throws {
        let table = try Actions.loadBundled()
        for a in table {
            XCTAssertEqual(Placement.places(of: a.id).count, 1, "\(a.id): \(Placement.places(of: a.id))")
        }
        XCTAssertTrue(Placement.misplaced(in: table).isEmpty)
        XCTAssertEqual(Placement.undeclaredRows(in: table), [])
    }

    func testARowAddedAndForgottenIsCaught() throws {
        let added = try Actions.parse(try Actions.bundledText() + "new-thing\tA new thing\tnice-dns new\tno\tyes\n")
        let m = Placement.misplaced(in: added)
        XCTAssertEqual(m.map(\.id), ["new-thing"])
        XCTAssertEqual(m.first?.places, [])
    }

    func testTheFourChoicesAreNotPlainButtons() {
        let ids = Placement.buttons().map(\.id)
        for id in choiceIds {
            XCTAssertFalse(ids.contains(id), id)
            XCTAssertEqual(Placement.place(of: id), .selector, id)
        }
        XCTAssertEqual(ids, ["reinstall", "restart", "uninstall", "update-check", "health-start", "health-stop", "health-run", "failures"])
        XCTAssertEqual(Placement.place(of: "update"), .updateBanner)
        XCTAssertEqual(Placement.place(of: "install"), .installView)
    }

    func testTheQuestionForEachChoice() {
        let tail = " The stack is reinstalled from the kept source. This takes a few minutes and DNS stops briefly."
        XCTAssertEqual(StackChoice.question(for: "proxy-haproxy"), "Switch the proxy to haproxy?" + tail)
        XCTAssertEqual(StackChoice.question(for: "proxy-socat"), "Switch the proxy to socat?" + tail)
        XCTAssertEqual(StackChoice.question(for: "pihole-standard"), "Switch Pi-hole to standard?" + tail)
        XCTAssertEqual(StackChoice.question(for: "pihole-hardened"), "Switch Pi-hole to hardened?" + tail)
        XCTAssertNil(StackChoice.question(for: "restart"))
    }

    func testPendingIsSetKeptThroughTheEndAndClearedByTheNextRead() throws {
        let st = try installedStatus()
        for (sel, was, other) in [(StackChoice.proxy, "socat", "haproxy"), (StackChoice.pihole, "standard", "hardened")] {
            var s = SwitchState()
            XCTAssertEqual(s.shown(sel, status: st), was)
            s.ask(sel.id(other))
            XCTAssertEqual(s.shown(sel, status: st), other)
            s.started(sel.id(other))
            XCTAssertEqual(s.pending[sel.kind], other)
            s.statusRead()
            XCTAssertEqual(s.shown(sel, status: st), other, "a read during the run")
            s.ended(sel.id(other), succeeded: true)
            XCTAssertEqual(s.shown(sel, status: st), other, "ended, no read yet")
            s.statusRead()
            XCTAssertNil(s.pending[sel.kind])
            XCTAssertEqual(s.shown(sel, status: st), was)
        }
    }

    func testAFailedSwitchAndADismissedQuestionGoBack() throws {
        let st = try installedStatus()
        for (sel, was, other) in [(StackChoice.proxy, "socat", "haproxy"), (StackChoice.pihole, "standard", "hardened")] {
            var f = SwitchState()
            f.ask(sel.id(other))
            f.started(sel.id(other))
            f.ended(sel.id(other), succeeded: false)
            XCTAssertNil(f.pending[sel.kind])
            XCTAssertEqual(f.shown(sel, status: st), was)
            var d = SwitchState()
            d.ask(sel.id(other))
            d.dismiss()
            XCTAssertEqual(d.shown(sel, status: st), was)
        }
        XCTAssertEqual(StackChoice.failedNotice(for: "proxy-socat", said: "failed (exit 3)"),
                       "The switch did not happen: failed (exit 3); the proxy is unchanged")
        XCTAssertNil(StackChoice.failedNotice(for: "restart", said: "failed (exit 1)"))
    }

    func testAnUnnamedOrUnknownValueIsUnknown() throws {
        var st = try installedStatus()
        st.install.variant = nil
        XCTAssertNil(SwitchState().shown(.proxy, status: st))
        XCTAssertEqual(SwitchState().shown(.pihole, status: st), "standard")
        st.install.pihole = "extra"
        XCTAssertNil(SwitchState().shown(.pihole, status: st))
        XCTAssertNil(SwitchState().shown(.proxy, status: nil))
    }

    func testTheUpdateRowSaysWhenTheLastCheckRan() throws {
        let u = try Status.parse(try fixture("status-update-available.tsv")).update
        XCTAssertEqual(updateRow(u, now: 1794251900 + 600), "available: 0f6a6e7c3d2b (checked 10 min ago)")
        let n = try installedStatus().update
        XCTAssertEqual(updateRow(n, now: 1794251900), "not checked yet")
        XCTAssertEqual(ago(700, now: 1000), "5 min ago")
        XCTAssertEqual(ago(1010, now: 1000), "in the future")
    }
}
