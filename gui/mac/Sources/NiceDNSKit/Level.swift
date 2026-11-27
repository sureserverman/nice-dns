// The status level (GUI spec section 3): the one decision the hero, the lookup
// path and the menu-bar glyph all share, so they can never disagree. And the
// check table (gui/share/checks.tsv, bundled as Resources/checks.tsv): what
// each `obs` name is called, where it sits on the lookup path and how bad it
// is when it is unhealthy. AppKit-free, so KitCheck tests it.
import Foundation

/// How the stack is doing, first match wins:
/// `error` (the status cannot be read), `notInstalled`, `waiting` (`controller
/// stale never`: no pass yet), `stale` (a number of seconds or `future`),
/// `down` (a check whose level when unhealthy is down, the verdict naming
/// `chain-resolves`, or every route unhealthy), `attention` (any other check
/// that is not healthy, a verdict that is not OK, or a file that cannot be
/// read) and `ok`.
public enum Level: String, CaseIterable, Equatable {
    case error, notInstalled, waiting, stale, down, attention, ok

    public static func of(_ view: StatusView) -> Level {
        switch view {
        case .error: return .error
        case .notInstalled: return .notInstalled
        case .installed(let s), .unreadable(let s): return of(s)
        }
    }

    public static func of(_ s: Status) -> Level {
        // A missing or unreadable `stale` row is not read as stale.
        switch s.controller.stale {
        case .never?: return .waiting
        case .seconds?, .future?: return .stale
        case .no?, nil: break
        }
        let routes = s.obs.filter { $0.name.hasPrefix("route:") }
        let everyRouteDown = !routes.isEmpty && routes.allSatisfy { $0.verdict == "unhealthy" }
        if s.obs.contains(where: { Checks.state(of: $0) == .down })
            || verdictNames("chain-resolves", s.controller.verdict) || everyRouteDown {
            return .down
        }
        let verdict = s.controller.verdict ?? "unknown"
        if verdict != "OK" || s.obs.contains(where: { $0.verdict != "healthy" }) || !s.unreadable.isEmpty {
            return .attention
        }
        return .ok
    }

    /// Whether `name` is in the bracketed names of a `FAIL [a b]` or
    /// `INDETERMINATE [a b]` verdict (the part after ` indeterminate=(` does not count).
    static func verdictNames(_ name: String, _ verdict: String?) -> Bool {
        guard let v = verdict, let open = v.firstIndex(of: "["), let close = v[open...].firstIndex(of: "]") else { return false }
        return v[v.index(after: open)..<close].split(separator: " ").contains { $0 == name }
    }

    /// The SF Symbol of the hero (BUILD-MACOS): a shield for the stack's own
    /// state, a triangle where the data is old or only part of it is wrong.
    public var heroSymbol: String {
        switch self {
        case .ok: return "checkmark.shield"
        case .attention, .stale: return "exclamationmark.triangle"
        case .down, .error: return "exclamationmark.shield"
        case .waiting, .notInstalled: return "shield"
        }
    }

    /// The menu-bar item's symbol: it varies with the level, so the state
    /// does not rest on colour alone.
    public var menuSymbol: String {
        switch self {
        case .ok: return "checkmark.shield.fill"
        case .attention, .stale: return "exclamationmark.shield.fill"
        case .down, .error: return "xmark.shield.fill"
        case .notInstalled: return "shield.slash"
        case .waiting: return "shield"
        }
    }

    /// The menu-bar symbol while the first status read is under way.
    public static let loadingMenuSymbol = "shield"

    /// The words that say it besides colour.
    public var word: String {
        switch self {
        case .ok: return "protected"
        case .attention: return "needs attention"
        case .stale: return "out of date"
        case .down: return "down"
        case .error: return "unreadable"
        case .notInstalled: return "not installed"
        case .waiting: return "waiting for the first check"
        }
    }

    /// The tint of the hero and the glyph.
    public var tone: Tone {
        switch self {
        case .ok: return .ok
        case .attention, .stale: return .attention
        case .down, .error: return .down
        case .notInstalled, .waiting: return .neutral
        }
    }

    /// The menu-bar glyph's colour for this level.
    public var glyph: Glyph {
        switch tone {
        case .ok: return .green
        case .attention: return .amber
        case .down: return .red
        case .neutral: return .grey
        }
    }
}

/// How a hero, a path node or a check row is tinted.
public enum Tone: String, Equatable {
    case neutral, ok, attention, down
}

/// One row of the check table.
public struct CheckInfo: Equatable {
    public var id: String
    public var group: String
    public var name: String
    /// `computer`, `pihole`, `unbound`, `tor`, `resolver`, or empty.
    public var pathNode: String
    /// `down` or `attention`.
    public var levelWhenUnhealthy: Level
    public var headline: String
    public var valueWhenHealthy: String
    public var notes: String
}

/// How one `obs` row stands.
public enum CheckState: Equatable {
    case healthy, attention, down
}

public enum Checks {
    /// The wildcard row's id: any name the table does not list.
    public static let other = "*"

    /// The columns of the table, in order.
    static let columns = ["id", "group", "name", "path_node", "level_when_unhealthy",
                          "headline_when_unhealthy", "value_when_healthy", "notes"]

    /// The bundled table's text, exactly as committed.
    public static func bundledText() throws -> String { try Actions.bundledResource("checks") }

    public static func loadBundled() throws -> [CheckInfo] { try parse(bundledText()) }

    /// The bundled table; KitCheck and the tests refuse a bad one.
    public static let all: [CheckInfo] = {
        do { return try loadBundled() } catch { fatalError("the bundled checks.tsv: \(error)") }
    }()

    /// Parse a check table: a header row, then one row per name. Any
    /// malformed row refuses the whole table.
    public static func parse(_ text: String) throws -> [CheckInfo] {
        var out: [CheckInfo] = []
        for (i, line) in splitLines(text).enumerated() {
            let n = i + 1
            if line.isEmpty { continue }
            let f = line.components(separatedBy: "\t")
            guard f.count == columns.count else { throw ActionError("line \(n): \(f.count) fields, not \(columns.count)") }
            if i == 0 {
                guard f == columns else { throw ActionError("line 1: the header is not \(columns.joined(separator: " "))") }
                continue
            }
            guard !f[0].isEmpty, !f[1].isEmpty, !f[2].isEmpty, !f[5].isEmpty else {
                throw ActionError("line \(n): an empty id, group, name or headline")
            }
            let level: Level
            switch f[4] {
            case "down": level = .down
            case "attention": level = .attention
            default: throw ActionError("line \(n): level_when_unhealthy is '\(f[4])', not down or attention")
            }
            if out.contains(where: { $0.id == f[0] }) { throw ActionError("line \(n): duplicate id '\(f[0])'") }
            out.append(CheckInfo(id: f[0], group: f[1], name: f[2], pathNode: f[3], levelWhenUnhealthy: level,
                                 headline: f[5], valueWhenHealthy: f[6], notes: f[7]))
        }
        guard out.contains(where: { $0.id == other }) else { throw ActionError("no '*' row for the names the table does not list") }
        return out
    }

    /// The row of `id`; nil when the table does not list it.
    public static func info(_ id: String) -> CheckInfo? {
        all.first { $0.id == id && $0.id != other }
    }

    /// The row of `id`, or the `*` row made out of the raw id: it is shown
    /// under Other with its id as its name and "{id}: check failed" as its
    /// headline, and never dropped (the contract lets new names appear).
    public static func resolve(_ id: String) -> CheckInfo {
        if let i = info(id) { return i }
        var o = all.first { $0.id == other }!
        o.id = id
        o.name = id
        o.headline = "\(id): check failed"
        return o
    }

    /// How an observation stands: healthy; down when it is unhealthy and the
    /// table says so; attention otherwise (unhealthy or indeterminate).
    public static func state(of o: Obs) -> CheckState {
        if o.verdict == "healthy" { return .healthy }
        if o.verdict == "unhealthy", resolve(o.name).levelWhenUnhealthy == .down { return .down }
        return .attention
    }
}
