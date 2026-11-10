import XCTest
@testable import NiceDNSKit

final class ActionsTests: XCTestCase {
    func words(_ id: String) -> [String] {
        guard let a = Actions.lookup(id) else { XCTFail("no action \(id)"); return [] }
        return (a.program.map { [$0] } ?? []) + a.args
    }

    func atBin(_ name: String) throws -> String { "/h/.local/bin/" + name }

    func testBundledTableEqualsTheSharedTable() throws {
        let shared = try String(contentsOf: shareURL("actions.tsv"), encoding: .utf8)
        XCTAssertEqual(try Actions.bundledText(), shared)
        XCTAssertEqual(try Actions.loadBundled(), try Actions.parse(shared))
    }

    func testTableParsesWithFiveFieldsPerRow() throws {
        let text = try Actions.bundledText()
        let rows = text.split(separator: "\n")
        XCTAssertTrue(rows.allSatisfy { $0.split(separator: "\t", omittingEmptySubsequences: false).count == 5 })
        XCTAssertEqual(Actions.all.count, rows.count)
        XCTAssertEqual(Actions.all.count, 14)
    }

    func testIdsAreUnique() {
        XCTAssertEqual(Set(Actions.all.map(\.id)).count, Actions.all.count)
    }

    func testReachEveryCliCommandAndControllerVerb() {
        func reached(_ program: String, _ verb: String) -> Bool {
            Actions.all.contains { $0.program == program && $0.args.first == verb }
        }
        for verb in ["install", "reinstall", "restart", "uninstall", "update", "bridges"] {
            XCTAssertTrue(reached("nice-dns", verb), "nice-dns \(verb)")
        }
        for verb in ["start", "stop", "run"] {
            XCTAssertTrue(reached("nice-dns-health", verb), "nice-dns-health \(verb)")
        }
        for a in Actions.all {
            XCTAssertTrue([nil, "nice-dns", "nice-dns-health"].contains(a.program), a.id)
        }
    }

    func testExactWords() {
        XCTAssertEqual(words("bridges-off"), ["nice-dns", "bridges", "off"])
        XCTAssertEqual(words("health-run"), ["nice-dns-health", "run"])
        XCTAssertEqual(words("update-check"), ["nice-dns", "update", "--check"])
        XCTAssertEqual(words("open-admin"), [])
        XCTAssertEqual(words("show-password-path"), [])
    }

    func testConfirmAndInstalledFlags() {
        for id in ["reinstall", "uninstall", "update"] {
            XCTAssertEqual(Actions.lookup(id)?.needsConfirm, true, id)
        }
        XCTAssertEqual(Actions.lookup("restart")?.needsConfirm, false)
        XCTAssertEqual(Actions.lookup("install")?.needsInstalled, false)
        XCTAssertTrue(Actions.all.filter { $0.id != "install" }.allSatisfy(\.needsInstalled))
        XCTAssertEqual(Actions.lookup("bridges-off")?.label, "Turn bridges off")
        XCTAssertNil(Actions.lookup("nope"))
    }

    func testArgvRunsTheResolvedProgramWithTheTableWords() throws {
        func run(_ id: String) throws -> [String]? { try Actions.argv(id, choices: nil, resolve: atBin) }
        XCTAssertEqual(try run("bridges-off"), ["/h/.local/bin/nice-dns", "bridges", "off"])
        XCTAssertEqual(try run("bridges-on"), ["/h/.local/bin/nice-dns", "bridges", "on"])
        XCTAssertEqual(try run("restart"), ["/h/.local/bin/nice-dns", "restart"])
        XCTAssertEqual(try run("health-start"), ["/h/.local/bin/nice-dns-health", "start"])
        XCTAssertNil(try run("open-admin"))
        XCTAssertThrowsError(try Actions.argv("restart", choices: nil) { name in
            throw CommandNotFound(path: "/h/.local/bin/" + name)
        }) { e in
            XCTAssertEqual("\(e)", "nice-dns is not installed: looked for /h/.local/bin/nice-dns")
        }
        XCTAssertThrowsError(try run("nope"))
    }

    func testReinstallPassesTheChosenVariantFlavourAndBranch() throws {
        let c = Choices(variant: "socat", pihole: "hardened", branch: "main")
        XCTAssertEqual(try Actions.argv("reinstall", choices: c, resolve: atBin),
                       ["/h/.local/bin/nice-dns", "reinstall", "socat", "--hardened", "--branch", "main"])
        var std = c
        std.pihole = "standard"
        XCTAssertEqual(try std.words()[1], "--standard")
        for bad in [
            Choices(variant: "tor", pihole: "hardened", branch: "main"),
            Choices(variant: "socat", pihole: "extra", branch: "main"),
            Choices(variant: "socat", pihole: "hardened", branch: "--local"),
            Choices(variant: "socat", pihole: "hardened", branch: "a b"),
            Choices(variant: "socat", pihole: "hardened", branch: " "),
        ] {
            XCTAssertThrowsError(try Actions.argv("reinstall", choices: bad, resolve: atBin), "\(bad)")
        }
        // Without choices reinstall uses the recorded ones.
        XCTAssertEqual(try Actions.argv("reinstall", choices: nil, resolve: atBin),
                       ["/h/.local/bin/nice-dns", "reinstall"])
    }

    func testMalformedRowsAreRefused() throws {
        func refusal(_ t: String) -> String {
            do { _ = try Actions.parse(t); return "accepted" } catch { return "\(error)" }
        }
        XCTAssertTrue(refusal("a\tA\tnice-dns x\tyes\n").contains("4 fields"))
        XCTAssertTrue(refusal("a\tA\tnice-dns x\tyes\tno\textra\n").contains("6 fields"))
        XCTAssertTrue(refusal("a\tA\tnice-dns x\tmaybe\tno\n").contains("needs-confirm"))
        XCTAssertTrue(refusal("a\tA\tnice-dns x\tno\tyes\na\tB\tnice-dns y\tno\tyes\n").contains("duplicate"))
        XCTAssertTrue(refusal("a\tA\tnice-dns  x\tno\tyes\n").contains("malformed"))
        XCTAssertTrue(refusal("a\t\tnice-dns x\tno\tyes\n").contains("empty"))
        XCTAssertNil(try Actions.parse("a\tA\t-\tno\tno\n")[0].program)
    }
}
