// Where each action of the table is drawn, and the two selectors (the proxy
// and the Pi-hole flavour): their choices, the question asked before a
// switch, and the value shown while one is asked for or runs. AppKit-free,
// so KitCheck tests it.
import Foundation

/// The one place an action of the table is drawn.
public enum Place: String, CaseIterable, CustomStringConvertible {
    /// A plain button in the window's Actions panel and an item of the menu.
    case button
    /// The bridges switch (the window's toggle, the menu's checked item).
    case bridgesSwitch
    /// A choice of the proxy or the Pi-hole selector.
    case selector
    /// The update banner (the window's banner, the menu's first item).
    case updateBanner
    /// The not-installed page's Install button.
    case installView
    /// The Admin panel's buttons (they run no command).
    case adminPanel

    public var description: String { rawValue }
}

public enum Placement {
    /// The ids each place draws, declared one place at a time. A row of the
    /// table no place names is drawn nowhere; one two places name is drawn
    /// twice. KitCheck and the tests refuse both.
    public static let declared: [(place: Place, ids: [String])] = [
        (.button, ["reinstall", "restart", "uninstall", "update-check",
                   "health-start", "health-stop", "health-run", "failures"]),
        (.bridgesSwitch, ["bridges-on", "bridges-off"]),
        (.selector, StackChoice.all.flatMap(\.ids)),
        (.updateBanner, ["update"]),
        (.installView, ["install"]),
        (.adminPanel, ["open-admin", "show-password-path"]),
    ]

    /// Every place that names `id`, in declaration order.
    public static func places(of id: String) -> [Place] {
        declared.filter { $0.ids.contains(id) }.map(\.place)
    }

    /// The one place of `id`; nil when it has none or more than one.
    public static func place(of id: String) -> Place? {
        let p = places(of: id)
        return p.count == 1 ? p[0] : nil
    }

    /// The plain buttons, in table order: the rows whose one place is a button.
    public static func buttons(in table: [Action] = Actions.all) -> [Action] {
        table.filter { place(of: $0.id) == .button }
    }

    /// The rows of `table` that do not have exactly one place, with the
    /// places that name them.
    public static func misplaced(in table: [Action]) -> [(id: String, places: [Place])] {
        table.compactMap { a in
            let p = places(of: a.id)
            return p.count == 1 ? nil : (a.id, p)
        }
    }

    /// The declared ids `table` has no row for.
    public static func undeclaredRows(in table: [Action]) -> [String] {
        let ids = Set(table.map(\.id))
        return declared.flatMap(\.ids).filter { !ids.contains($0) }
    }
}

/// One of the two selectors: the proxy (`install variant`) or the Pi-hole
/// flavour (`install pihole`). Each choice is a row of the table,
/// `<kind>-<choice>`, which runs `nice-dns switch <kind> <choice>`.
public struct StackChoice: Equatable {
    public enum Kind: String, CaseIterable {
        case proxy, pihole
    }

    public let kind: Kind
    public let title: String
    public let choices: [String]

    public static let proxy = StackChoice(kind: .proxy, title: "Proxy", choices: ["haproxy", "socat"])
    public static let pihole = StackChoice(kind: .pihole, title: "Pi-hole", choices: ["standard", "hardened"])
    public static let all = [proxy, pihole]

    public static func of(_ kind: Kind) -> StackChoice {
        kind == .proxy ? proxy : pihole
    }

    /// The action id of `choice`.
    public func id(_ choice: String) -> String { "\(kind.rawValue)-\(choice)" }

    /// The action ids of its choices.
    public var ids: [String] { choices.map(id) }

    /// The selector and the choice action `id` picks; nil for any other id.
    public static func choice(of id: String) -> (selector: StackChoice, choice: String)? {
        for s in all {
            if let c = s.choices.first(where: { s.id($0) == id }) { return (s, c) }
        }
        return nil
    }

    /// What `status` says is installed; nil when it names nothing or a value
    /// outside the choices (the selector is then disabled and shows unknown).
    public func installed(in status: Status?) -> String? {
        let v: String?
        switch kind {
        case .proxy: v = status?.install.variant
        case .pihole: v = status?.install.pihole
        }
        return v.flatMap { choices.contains($0) ? $0 : nil }
    }

    /// The question asked before `choice` is switched to (DEC-018).
    public func question(_ choice: String) -> String {
        let head: String
        switch kind {
        case .proxy: head = "Switch the proxy to \(choice)?"
        case .pihole: head = "Switch Pi-hole to \(choice)?"
        }
        return head + " The stack is reinstalled from the kept source. This takes a few minutes and DNS stops briefly."
    }

    /// The question for action `id`; nil when `id` is not a choice.
    public static func question(for id: String) -> String? {
        choice(of: id).map { $0.selector.question($0.choice) }
    }

    /// The notice after a switch that failed: `said` is the outcome line
    /// (`failed (exit 3)`, `authorisation cancelled (exit 126)`).
    public static func failedNotice(for id: String, said: String) -> String? {
        guard let s = choice(of: id)?.selector else { return nil }
        let what = s.kind == .proxy ? "the proxy" : "Pi-hole"
        return "The switch did not happen: \(said); \(what) is unchanged"
    }
}

/// What each selector shows besides the status: the choice being asked
/// about, then the one that runs. A switch that runs keeps its choice until
/// the first status read after the command ends (a switch that worked does
/// not flick back first); one that failed goes back at once; a dismissed
/// question goes back too.
public struct SwitchState: Equatable {
    /// The choice asked about, until the question is answered.
    public private(set) var asked: [StackChoice.Kind: String] = [:]
    /// The choice that runs, or ran and is waiting for the status read.
    public private(set) var pending: [StackChoice.Kind: String] = [:]
    /// The pending choices whose command has ended.
    private var done: Set<StackChoice.Kind> = []

    public init() {}

    /// The question for choice action `id` is asked.
    public mutating func ask(_ id: String) {
        guard let p = StackChoice.choice(of: id) else { return }
        asked[p.selector.kind] = p.choice
    }

    /// The question was answered Not now or dismissed.
    public mutating func dismiss() {
        asked = [:]
    }

    /// Action `id` started; only a choice action changes anything.
    public mutating func started(_ id: String) {
        asked = [:]
        guard let p = StackChoice.choice(of: id) else { return }
        pending[p.selector.kind] = p.choice
        done.remove(p.selector.kind)
    }

    /// Action `id` ended: a failure goes back now, a success at the next read.
    public mutating func ended(_ id: String, succeeded ok: Bool) {
        guard let k = StackChoice.choice(of: id)?.selector.kind, pending[k] != nil else { return }
        if ok {
            done.insert(k)
        } else {
            pending[k] = nil
        }
    }

    /// A status read landed: the switches that ended now show the status.
    public mutating func statusRead() {
        for k in done { pending[k] = nil }
        done = []
    }

    /// What `selector` shows: the choice running, else the one asked about,
    /// else the installed one; nil (unknown) when the status names neither
    /// of the two.
    public func shown(_ selector: StackChoice, status: Status?) -> String? {
        guard let installed = selector.installed(in: status) else { return nil }
        return pending[selector.kind] ?? asked[selector.kind] ?? installed
    }
}
