// The shared action table, gui/share/actions.tsv, bundled as a resource of
// this module (Resources/actions.tsv, a committed copy: `make strings`
// refreshes it from ../share, `make strings-check` and KitCheck fail on drift).
//
// One header-less row per action:
// `id<TAB>label<TAB>command words<TAB>needs-confirm<TAB>needs-installed`.
// The command words are the program (`nice-dns` or `nice-dns-health`) and its
// arguments, space-separated; `-` marks an action that runs no subprocess.
import Foundation

public struct Action: Equatable {
    public var id: String
    public var label: String
    /// `nil` for an action that is not a subprocess.
    public var program: String?
    public var args: [String]
    public var needsConfirm: Bool
    public var needsInstalled: Bool
}

/// Why an action table, an action or its choices were refused.
public struct ActionError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A command neither place the installer publishes it holds; `path` is the
/// one the GUI names.
public struct CommandNotFound: Error, Equatable, CustomStringConvertible {
    public var path: String
    public init(path: String) { self.path = path }
    public var description: String { "\(path) not found" }
}

/// The reinstall dialog's choices, prefilled from `status`.
public struct Choices: Equatable {
    public var variant: String
    public var pihole: String
    public var branch: String

    public init(variant: String, pihole: String, branch: String) {
        self.variant = variant
        self.pihole = pihole
        self.branch = branch
    }

    /// The words `nice-dns reinstall` takes for these choices, or why they
    /// cannot be passed (an unknown variant or flavour, an empty branch, or one
    /// that looks like an option).
    public func words() throws -> [String] {
        guard variant == "haproxy" || variant == "socat" else {
            throw ActionError("unknown proxy '\(variant)'")
        }
        let flavour: String
        switch pihole {
        case "standard": flavour = "--standard"
        case "hardened": flavour = "--hardened"
        default: throw ActionError("unknown Pi-hole flavour '\(pihole)'")
        }
        let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty || b.hasPrefix("-")
            || b.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            throw ActionError("'\(branch)' is not a branch name")
        }
        return [variant, flavour, "--branch", b]
    }
}

public enum Actions {
    /// The resource bundle SwiftPM builds for this module (`<package>_<target>`).
    public static let resourceBundleName = "NiceDNS_NiceDNSKit.bundle"

    private final class Marker {}

    /// Where the resource bundle is looked for, in order: an app's
    /// `Contents/Resources` (where the app bundle must carry it), beside the
    /// executable (`swift build`, `swift run`), beside the test bundle
    /// (`swift test`). SwiftPM's own `Bundle.module` is not used: it looks at
    /// the app's root and then at an absolute build path, so an app missing
    /// the bundle would work on the Mac that built it and crash elsewhere.
    public static func resourceBundleCandidates() -> [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r) }
        dirs.append(Bundle.main.bundleURL)
        dirs.append(Bundle(for: Marker.self).bundleURL.deletingLastPathComponent())
        return dirs.map { $0.appendingPathComponent(resourceBundleName) }
    }

    /// The bundled table's text, exactly as committed.
    public static func bundledText() throws -> String {
        let candidates = resourceBundleCandidates()
        for c in candidates {
            if let b = Bundle(url: c), let url = b.url(forResource: "actions", withExtension: "tsv") {
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        throw ActionError("actions.tsv not found: looked in " + candidates.map(\.path).joined(separator: ", "))
    }

    /// The bundled table, parsed.
    public static func loadBundled() throws -> [Action] {
        try parse(bundledText())
    }

    /// Every action of the bundled table, in table order. The table ships in
    /// the bundle; KitCheck and the tests refuse a bad one.
    public static let all: [Action] = {
        do { return try loadBundled() } catch { fatalError("the bundled actions.tsv: \(error)") }
    }()

    public static func lookup(_ id: String) -> Action? {
        all.first { $0.id == id }
    }

    /// Parse an action table; any malformed row refuses the whole table.
    public static func parse(_ text: String) throws -> [Action] {
        var out: [Action] = []
        for (i, line) in splitLines(text).enumerated() {
            let n = i + 1
            if line.isEmpty { continue }
            let f = line.components(separatedBy: "\t")
            guard f.count == 5 else { throw ActionError("line \(n): \(f.count) fields, not 5") }
            let (id, label, words, confirm, installed) = (f[0], f[1], f[2], f[3], f[4])
            if id.isEmpty || label.isEmpty || words.isEmpty {
                throw ActionError("line \(n): an empty id, label or command")
            }
            if out.contains(where: { $0.id == id }) {
                throw ActionError("line \(n): duplicate id '\(id)'")
            }
            var program: String?
            var args: [String] = []
            if words != "-" {
                let w = words.components(separatedBy: " ")
                args = Array(w.dropFirst())
                guard let p = w.first, !p.isEmpty, !args.contains(where: \.isEmpty) else {
                    throw ActionError("line \(n): malformed command '\(words)'")
                }
                program = p
            }
            out.append(Action(
                id: id, label: label, program: program, args: args,
                needsConfirm: try flag(confirm, "needs-confirm", n),
                needsInstalled: try flag(installed, "needs-installed", n)))
        }
        return out
    }

    /// The argv that runs action `id`: its program found by `resolve`, then
    /// the table's words, and for `reinstall` with `choices` those choices.
    /// `nil` for an action that runs no command.
    public static func argv(_ id: String, choices: Choices?, resolve: (String) throws -> String) throws -> [String]? {
        guard let a = lookup(id) else { throw ActionError("no action '\(id)'") }
        guard let program = a.program else { return nil }
        let path: String
        do {
            path = try resolve(program)
        } catch let nf as CommandNotFound {
            throw ActionError("\(program) is not installed: looked for \(nf.path)")
        }
        var v = [path] + a.args
        if let c = choices, id == "reinstall" {
            v += try c.words()
        }
        return v
    }

    private static func flag(_ v: String, _ what: String, _ n: Int) throws -> Bool {
        switch v {
        case "yes": return true
        case "no": return false
        default: throw ActionError("line \(n): \(what) is '\(v)', not yes or no")
        }
    }
}
