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

    func testTheFourChoicesAreSelectorsAndEachSharedComponentIsOnePlace() {
        for id in choiceIds {
            XCTAssertEqual(Placement.place(of: id), .selector, id)
        }
        XCTAssertEqual(Placement.place(of: "health-run"), .statusHeader)
        XCTAssertEqual(Placement.place(of: "update-check"), .updateRow)
        XCTAssertEqual(Placement.place(of: "update"), .updateRow)
        XCTAssertEqual(Placement.place(of: "bridges-on"), .bridgesSwitch)
        XCTAssertEqual(Placement.place(of: "open-admin"), .adminRow)
        XCTAssertEqual(Placement.place(of: "show-password-path"), .adminRow)
        XCTAssertEqual(Placement.place(of: "health-start"), .autoChecks)
        XCTAssertEqual(Placement.place(of: "health-stop"), .autoChecks)
        XCTAssertEqual(Placement.place(of: "failures"), .repairsHeader)
        XCTAssertEqual(Placement.place(of: "restart"), .maintenance)
        XCTAssertEqual(Placement.place(of: "reinstall"), .maintenance)
        XCTAssertEqual(Placement.place(of: "uninstall"), .maintenance)
        XCTAssertEqual(Placement.place(of: "install"), .installView)
    }

    func testTheQuestionForEachChoice() {
        let tail = " The stack is rebuilt from the kept source. This takes a few minutes and DNS stops briefly. The running stack stays if anything fails."
        XCTAssertEqual(StackChoice.question(for: "proxy-haproxy"), "Switch the Tor proxy to haproxy?" + tail)
        XCTAssertEqual(StackChoice.question(for: "proxy-socat"), "Switch the Tor proxy to socat?" + tail)
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
}
