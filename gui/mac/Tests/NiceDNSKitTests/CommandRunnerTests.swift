import XCTest
@testable import NiceDNSKit

final class CommandRunnerTests: XCTestCase {
    func testLinesStreamInOrderThenOneExitLast() throws {
        let r = try CommandRunner.collect(["/bin/sh", "-c", "echo one; echo err >&2; printf 'two\\nthree'; exit 3"])
        XCTAssertEqual(r.stdout, ["one", "two", "three"])
        XCTAssertEqual(r.stderr, ["err"])
        XCTAssertEqual(r.exit, .code(3))
        XCTAssertEqual(r.events.last, .exit(.code(3)))
        XCTAssertEqual(r.events.filter { if case .exit = $0 { return true }; return false }.count, 1)
    }

    func testLinesArriveBeforeTheProcessEnds() throws {
        let first = expectation(description: "first line")
        let done = expectation(description: "exit")
        var sawExitBeforeLine = false
        var gotLine = false
        _ = try CommandRunner.spawn(["/bin/sh", "-c", "echo early; sleep 1; echo late"]) { ev in
            switch ev {
            case .line(.stdout, "early"): gotLine = true; first.fulfill()
            case .exit: sawExitBeforeLine = !gotLine; done.fulfill()
            default: break
            }
        }
        // The first line is delivered while the command still sleeps.
        wait(for: [first], timeout: 0.9)
        wait(for: [done], timeout: 5)
        XCTAssertFalse(sawExitBeforeLine)
    }

    func testSignalIsReported() throws {
        let r = try CommandRunner.collect(["/bin/sh", "-c", "kill -TERM $$"])
        XCTAssertEqual(r.exit, .signal(15))
        XCTAssertEqual("\(r.exit!)", "killed by signal 15")
    }

    func testAMissingProgramIsAnErrorNotACrash() {
        XCTAssertThrowsError(try CommandRunner.collect(["/nonexistent/nice-dns", "status"]))
        XCTAssertThrowsError(try CommandRunner.collect([]))
        XCTAssertThrowsError(try CommandRunner.collect(["no-such-program-nice-dns-xyz"], environment: ["PATH": "/usr/bin:/bin"]))
    }

    func testBareNamesAreFoundOnThePathGiven() throws {
        let fakebin = shareURL("fixtures", "fakebin").path
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("nice-dns-fake-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: record) }
        let r = try CommandRunner.collect(["nice-dns", "bridges", "off"], environment: [
            "PATH": fakebin + ":/usr/bin:/bin", "NICE_DNS_FAKE_RECORD": record, "NICE_DNS_FAKE_EXIT": "126",
        ])
        XCTAssertEqual(r.exit, .code(126))
        XCTAssertEqual(r.stdout.last, "fake nice-dns: done")
        XCTAssertTrue(r.stderr.contains("nice-dns: authorisation cancelled"))
        XCTAssertEqual(try String(contentsOfFile: record, encoding: .utf8), "bridges off\n")
    }

    func testStdinIsClosed() throws {
        let r = try CommandRunner.collect(["/bin/sh", "-c", "cat; echo end"])
        XCTAssertEqual(r.stdout, ["end"])
        XCTAssertEqual(r.exit, .code(0))
    }
}
