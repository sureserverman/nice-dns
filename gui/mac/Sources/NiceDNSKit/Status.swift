// The `nice-dns status --tsv` contract (docs/cli-contract.md), schema
// `nice-dns-status/1`, parsed into typed records. AppKit-free.
import Foundation

public let statusSchema = "nice-dns-status/1"

/// Why a status text was refused.
public enum StatusParseError: Error, Equatable, CustomStringConvertible {
    /// The first line is not a schema row; `found` is that line (empty when
    /// there was no output at all).
    case noSchema(found: String)
    /// A schema row naming another schema.
    case wrongSchema(found: String)

    public var description: String {
        switch self {
        case .noSchema(let found) where found.isEmpty:
            return "no schema line: the status output is empty"
        case .noSchema(let found):
            return "no schema line: the first line is '\(found)'"
        case .wrongSchema(let found):
            return "schema '\(found)' is not \(statusSchema)"
        }
    }
}

/// `controller stale`: `no`, a number of seconds, `never` or `future`.
public enum Stale: Equatable, CustomStringConvertible {
    case no
    case seconds(UInt64)
    case never
    case future

    public static func parse(_ v: String) -> Stale? {
        switch v {
        case "no": return .no
        case "never": return .never
        case "future": return .future
        default: return UInt64(v).map(Stale.seconds)
        }
    }

    public var description: String {
        switch self {
        case .no: return "fresh"
        case .seconds(let s): return "stale \(s)s"
        case .never: return "no pass yet"
        case .future: return "pass dated in the future"
        }
    }
}

/// An `<epoch>|never` value (`controller last_pass`, `bridges last_refresh`).
public enum Moment: Equatable {
    case at(UInt64)
    case never

    public static func parse(_ v: String) -> Moment? {
        v == "never" ? .never : UInt64(v).map(Moment.at)
    }
}

public enum UpdateResult: Equatable {
    case current, available, unknown
}

public struct Install: Equatable {
    public var installed: Bool?
    public var generation: String?
    public var sourceCommit: String?
    public var branch: String?
    public var variant: String?
    public var pihole: String?
    public var platform: String?
    public var lock: String?
    public var hint: String?
}

public struct Controller: Equatable {
    public var mode: String?
    public var lastPass: Moment?
    public var verdict: String?
    public var stale: Stale?
    public var schedule: String?
}

/// One `obs<TAB>name<TAB>verdict<TAB>ms<TAB>reason` record.
public struct Obs: Equatable {
    public var name: String
    public var verdict: String
    public var ms: UInt64?
    public var reason: String

    public init(name: String, verdict: String, ms: UInt64?, reason: String) {
        self.name = name
        self.verdict = verdict
        self.ms = ms
        self.reason = reason
    }
}

/// `route selected <route id> <state generation>`.
public struct Route: Equatable {
    public var id: String
    public var generation: String

    public init(id: String, generation: String) {
        self.id = id
        self.generation = generation
    }
}

public struct Bridges: Equatable {
    public var mode: String?
    public var count: UInt32?
    public var lastRefresh: Moment?
}

public struct Update: Equatable {
    public var result: UpdateResult?
    public var neverChecked = false
    public var checkedAt: UInt64?
    public var remoteCommit: String?
}

public struct Helper: Equatable {
    public var path: String?
    public var installed: Bool?
    public var version: String?
}

public struct Admin: Equatable {
    public var url: String?
    public var passwordPath: String?
}

/// One `recent<TAB><epoch><TAB><target><TAB><result>` journal row.
public struct Recent: Equatable {
    public var epoch: UInt64?
    public var target: String
    public var result: String
}

/// A `<group> unreadable <reason>` row.
public struct Unreadable: Equatable {
    public var group: String
    public var reason: String

    public init(group: String, reason: String) {
        self.group = group
        self.reason = reason
    }
}

public struct Status: Equatable {
    public var install = Install()
    public var controller = Controller()
    public var obs: [Obs] = []
    public var route: Route?
    public var bridges = Bridges()
    public var update = Update()
    public var helper = Helper()
    public var admin = Admin()
    public var recent: [Recent] = []
    public var unreadable: [Unreadable] = []

    /// The `unreadable` reasons of one group, in order.
    public func unreadable(in group: String) -> [String] {
        unreadable.filter { $0.group == group }.map(\.reason)
    }

    /// Parse `status --tsv` output. The first line must be the schema row;
    /// rows of a group or key this reader does not know are ignored, as the
    /// contract says, and so is a known row too short to carry its values.
    public static func parse(_ input: String) throws -> Status {
        let lines = splitLines(input)
        try checkSchema(lines.first ?? "")

        var s = Status()
        for line in lines.dropFirst() {
            let f = line.components(separatedBy: "\t")
            if f.count < 3 { continue }
            let (group, key, val) = (f[0], f[1], f[2])
            if key == "unreadable" && f.count == 3 {
                s.unreadable.append(Unreadable(group: group, reason: val))
                continue
            }
            switch group {
            case "install":
                switch key {
                case "installed": s.install.installed = yesNo(val)
                case "generation": s.install.generation = val
                case "source_commit": s.install.sourceCommit = val
                case "branch": s.install.branch = val
                case "variant": s.install.variant = val
                case "pihole": s.install.pihole = val
                case "platform": s.install.platform = val
                case "lock": s.install.lock = val
                case "hint": s.install.hint = val
                default: break
                }
            case "controller":
                switch key {
                case "mode": s.controller.mode = val
                case "last_pass": s.controller.lastPass = Moment.parse(val)
                case "verdict": s.controller.verdict = val
                case "stale": s.controller.stale = Stale.parse(val)
                case "schedule": s.controller.schedule = val
                default: break
                }
            case "obs" where f.count >= 5:
                s.obs.append(Obs(name: key, verdict: val, ms: UInt64(f[3]), reason: f[4]))
            case "route" where key == "selected" && f.count >= 4:
                s.route = Route(id: val, generation: f[3])
            case "bridges":
                switch key {
                case "mode": s.bridges.mode = val
                case "count": s.bridges.count = UInt32(val)
                case "last_refresh": s.bridges.lastRefresh = Moment.parse(val)
                default: break
                }
            case "update":
                switch key {
                case "result":
                    switch val {
                    case "current": s.update.result = .current
                    case "available": s.update.result = .available
                    case "unknown": s.update.result = .unknown
                    default: s.update.result = nil
                    }
                    s.update.neverChecked = f.count > 3 && f[3] == "never-checked"
                case "checked_at": s.update.checkedAt = UInt64(val)
                case "remote_commit": s.update.remoteCommit = val
                default: break
                }
            case "helper":
                switch key {
                case "path": s.helper.path = val
                case "installed": s.helper.installed = yesNo(val)
                case "version": s.helper.version = val
                default: break
                }
            case "admin":
                switch key {
                case "url": s.admin.url = val
                case "password_path": s.admin.passwordPath = val
                default: break
                }
            case "recent" where f.count >= 4:
                s.recent.append(Recent(epoch: UInt64(key), target: val, result: f[3]))
            default:
                break
            }
        }
        return s
    }
}

/// Lines split on `\n` with a trailing `\r` dropped; no line after a final
/// `\n` (Rust's `str::lines`).
func splitLines(_ text: String) -> [String] {
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
}

private func yesNo(_ v: String) -> Bool? {
    switch v {
    case "yes": return true
    case "no": return false
    default: return nil
    }
}

private func checkSchema(_ first: String) throws {
    guard let tab = first.firstIndex(of: "\t"), first[..<tab] == "schema" else {
        throw StatusParseError.noSchema(found: first)
    }
    let found = String(first[first.index(after: tab)...])
    guard found == statusSchema else {
        throw StatusParseError.wrongSchema(found: found)
    }
}

/// What the window shows for one run of the status command.
public enum StatusView: Equatable {
    /// Exit 0 with an installed stack.
    case installed(Status)
    /// Nothing is installed: exit 1, or exit 2 with `install installed no`
    /// (the contract's 2 wins over 1) and its `unreadable` rows. `hint` is the
    /// `install hint` row, when given.
    case notInstalled(hint: String?, unreadable: [Unreadable])
    /// Exit 2 with rows of an installed stack: some file `status` reads cannot
    /// be read.
    case unreadable(Status)
    /// Anything else: exit 2 with nothing on stdout, another code, a signal, a
    /// refused schema, or rows that contradict the exit code.
    case error(String)
}

/// Map the status command's exit code (`nil`: killed by a signal) and its
/// stdout to what the window shows.
public func classify(exit code: Int32?, stdout: String) -> StatusView {
    func parsed() -> Result<Status, Error> { Result { try Status.parse(stdout) } }
    switch code {
    case 0?:
        switch parsed() {
        case .success(let s) where s.install.installed == true: return .installed(s)
        case .success: return .error("status exited 0 but does not say 'install installed yes'")
        case .failure(let e): return .error("\(e)")
        }
    case 1?:
        switch parsed() {
        case .success(let s) where s.install.installed == false:
            return .notInstalled(hint: s.install.hint, unreadable: [])
        case .success: return .error("status exited 1 but does not say 'install installed no'")
        case .failure(let e): return .error("\(e)")
        }
    case 2? where stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
        return .error("status exited 2 with nothing on stdout")
    case 2?:
        switch parsed() {
        case .success(let s) where s.install.installed == false:
            return .notInstalled(hint: s.install.hint, unreadable: s.unreadable)
        case .success(let s): return .unreadable(s)
        case .failure(let e): return .error("\(e)")
        }
    case let n?:
        return .error("status exited \(n)")
    case nil:
        return .error("status was killed by a signal")
    }
}
