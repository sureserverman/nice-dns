// What the Overview, Checks and Setup views and the menu-bar panel say, as
// pure functions from `Status` (GUI spec sections 3 to 7), so the window and
// the panel draw the same values and KitCheck can test them. AppKit-free.
import Foundation

private func plural(_ n: Int, _ one: String, _ many: String) -> String {
    n == 1 ? one : many
}

/// The first 12 characters of a commit.
public func shortCommit(_ sha: String) -> String { String(sha.prefix(12)) }

// MARK: Hero

/// The button the hero carries.
public enum HeroAction: Equatable {
    /// "Run Checks" (`health-run`).
    case runChecks
    /// "Turn On" (`health-start`): the schedule is stopped.
    case turnOn
}

/// The status header: one sentence that answers "is my DNS protected?".
public struct Hero: Equatable {
    public var level: Level
    public var title: String
    public var subtitle: String
    /// nil on the pages that have no controller to ask (not installed, error, loading).
    public var action: HeroAction?
    /// The subtitle in the panel's narrow header: at level ok only "Checked {ago}."
    public var brief: String

    public init(level: Level, title: String, subtitle: String, action: HeroAction?, brief: String? = nil) {
        self.level = level
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.brief = brief ?? subtitle
    }

    /// The hero while the first read is under way.
    public static let loading = Hero(level: .waiting, title: "Reading the status", subtitle: "", action: nil)

    /// The hero of a status that cannot be shown.
    public static func error(_ detail: String) -> Hero {
        Hero(level: .error, title: "The status cannot be shown", subtitle: detail, action: nil)
    }

    public static let notInstalled = Hero(level: .notInstalled, title: "nice-dns is not installed",
                                          subtitle: "This Mac is not using nice-dns.", action: nil)
}

/// The observations that are not healthy, in the status' order.
public func notHealthy(_ s: Status) -> [Obs] {
    s.obs.filter { $0.verdict != "healthy" }
}

/// When the last pass ran, as `ago`; nil when no pass is recorded.
func lastPassAgo(_ s: Status, now: UInt64) -> String? {
    if case .at(let e)? = s.controller.lastPass { return ago(e, now: now) }
    if case .seconds(let secs)? = s.controller.stale { return ago(now >= secs ? now - secs : 0, now: now) }
    return nil
}

/// The hero of an installed status (spec section 3, "Hero copy").
public func hero(_ s: Status, now: UInt64) -> Hero {
    let level = Level.of(s)
    let checked = lastPassAgo(s, now: now)
    func sentence(_ lead: String, _ tail: String?) -> String {
        [lead, tail].compactMap { $0 }.joined(separator: " ")
    }
    switch level {
    case .ok:
        return Hero(level: level, title: "DNS is protected",
                    subtitle: sentence("Every lookup leaves through Tor.", checked.map { "Checked \($0)." }), action: .runChecks,
                    brief: checked.map { "Checked \($0)." })
    case .attention:
        let bad = notHealthy(s)
        let onion = s.obs.first { $0.name == "route:cloudflare-onion" }
        if let sel = s.route?.id, sel != "cloudflare-onion", onion?.verdict == "unhealthy",
           s.obs.first(where: { $0.name == "route:\(sel)" })?.verdict == "healthy" {
            return Hero(level: level, title: "DNS works, on a backup route",
                        subtitle: "The Cloudflare onion route is not answering. Lookups still leave through Tor.", action: .runChecks)
        }
        if bad.map(\.name) == ["filtering"] {
            return Hero(level: level, title: "DNS works, but ads are not blocked",
                        subtitle: sentence("Lookups still leave through Tor.", checked.map { "Checked \($0)." }), action: .runChecks)
        }
        let n = bad.count
        if n == 0 {
            // The verdict is not OK, or a file could not be read, but no single check is to blame.
            let v = s.controller.verdict
            let why = (v != nil && v != "OK" && v != "unknown") ? "The controller said \(v!)." : "Some files could not be read."
            return Hero(level: level, title: "DNS works, but the last check was not clean",
                        subtitle: sentence(why, checked.map { "Checked \($0)." }), action: .runChecks)
        }
        let title = "DNS works, \(n) \(plural(n, "check needs", "checks need")) attention"
        return Hero(level: level, title: title, subtitle: checked.map { "Checked \($0)." } ?? "", action: .runChecks)
    case .stale:
        let last: String
        if s.controller.stale == .future {
            last = "The last check is dated in the future."
        } else {
            last = checked.map { "The last check ran \($0)." } ?? ""
        }
        if s.controller.schedule == "stopped" {
            return Hero(level: level, title: "Automatic checks are off", subtitle: last, action: .turnOn)
        }
        return Hero(level: level, title: "Status is out of date", subtitle: sentence(last, "Checks are overdue."), action: .runChecks)
    case .waiting:
        return Hero(level: level, title: "Waiting for the first check",
                    subtitle: "nice-dns has not checked this install yet.", action: .runChecks)
    case .down:
        let bad = s.obs.filter { $0.verdict == "unhealthy" }
        if let o = bad.first(where: { $0.name == "dns-owner" }) {
            return Hero(level: level, title: Checks.resolve(o.name).headline, subtitle: o.reason, action: .runChecks)
        }
        let routes = s.obs.filter { $0.name.hasPrefix("route:") }
        if !routes.isEmpty && routes.allSatisfy({ $0.verdict == "unhealthy" }) {
            return Hero(level: level, title: "DNS is down", subtitle: "No route through Tor is answering.", action: .runChecks)
        }
        if let o = bad.first(where: { Checks.state(of: $0) == .down }) {
            return Hero(level: level, title: "DNS is down", subtitle: Checks.resolve(o.name).headline, action: .runChecks)
        }
        return Hero(level: level, title: "DNS is down", subtitle: "The lookup chain is not resolving.", action: .runChecks)
    case .error, .notInstalled:
        // Not reached for a status that was read; the pages say their own.
        return level == .error ? .error("") : .notInstalled
    }
}

/// The hero of any view of the status, for the window's pages and the panel.
public func hero(_ view: StatusView, now: UInt64) -> Hero {
    switch view {
    case .installed(let s), .unreadable(let s): return hero(s, now: now)
    case .notInstalled: return .notInstalled
    case .error(let m): return .error(m)
    }
}

// MARK: Lookup path

public enum PathNodeID: String, CaseIterable, Equatable {
    case computer, pihole, unbound, tor, resolver

    /// The SF Symbol of the node (BUILD-MACOS).
    public var symbol: String {
        switch self {
        case .computer: return "display"
        case .pihole: return "line.3.horizontal.decrease.circle"
        case .unbound: return "server.rack"
        case .tor: return "circle.circle"
        case .resolver: return "globe"
        }
    }
}

public struct PathNode: Equatable {
    public var id: PathNodeID
    public var label: String
    public var caption: String
    public var tone: Tone
    /// The caption is drawn in the attention colour (a changed caption).
    public var captionChanged: Bool
    /// The line into this node is dashed: the route is a backup.
    public var dashedIn: Bool
}

public struct LookupPath: Equatable {
    public var nodes: [PathNode]
    public var footer: String

    /// One sentence for the accessibility label: no status rests on colour.
    public var sentence: String {
        let parts = nodes.map { n -> String in
            switch n.tone {
            case .neutral: return "\(n.label), \(n.caption)"
            case .ok: return "\(n.label), \(n.caption), working"
            case .attention: return "\(n.label), \(n.caption), needs attention"
            case .down: return "\(n.label), \(n.caption), down"
            }
        }
        return "How a lookup travels: " + parts.joined(separator: "; ") + ". " + footer
    }
}

/// The name of a route as the check table says it ("Cloudflare onion").
public func routeName(_ id: String) -> String {
    Checks.info("route:\(id)")?.name ?? id
}

/// "Cloudflare" or "Quad9", the provider of a route.
func routeProvider(_ id: String) -> String {
    if id.hasPrefix("cloudflare") { return "Cloudflare" }
    if id.hasPrefix("quad9") { return "Quad9" }
    return id
}

func routeCaption(_ id: String) -> String {
    switch id {
    case "cloudflare-onion": return "Onion resolver"
    case "cloudflare-exit", "quad9-exit": return "Via Tor exit"
    case "cloudflare-legacy": return "Onion, legacy port"
    default: return "Resolver"
    }
}

private func tone(_ s: CheckState) -> Tone {
    switch s {
    case .healthy: return .ok
    case .attention: return .attention
    case .down: return .down
    }
}

private func worst(_ tones: [Tone]) -> Tone {
    for t in [Tone.down, .attention, .ok] where tones.contains(t) { return t }
    return .neutral
}

/// The five nodes of "How a lookup travels" and the footer line under them.
public func lookupPath(_ s: Status) -> LookupPath {
    // Old results are not drawn in colour.
    let old = [Level.stale, .waiting].contains(Level.of(s))
    func nodeTone(_ id: PathNodeID) -> Tone {
        let t = worst(s.obs.filter { Checks.info($0.name)?.pathNode == id.rawValue }.map { tone(Checks.state(of: $0)) })
        return old ? .neutral : t
    }
    let routes = s.obs.filter { $0.name.hasPrefix("route:") }
    let selected = s.route?.id
    let selectedObs = selected.flatMap { id in s.obs.first { $0.name == "route:\(id)" } }
    let onionDown = s.obs.first { $0.name == "route:cloudflare-onion" }?.verdict != "healthy"
        && s.obs.contains { $0.name == "route:cloudflare-onion" }
    let backup = onionDown && selected != nil && selected != "cloudflare-onion"
    let exitBackup = backup

    var nodes: [PathNode] = []
    func changed(_ t: Tone, _ normal: String) -> (String, Bool) {
        switch t {
        case .attention: return ("Needs attention", true)
        case .down: return ("Not answering", true)
        default: return (normal, false)
        }
    }

    let comp = nodeTone(.computer)
    nodes.append(PathNode(id: .computer, label: "This Mac", caption: comp == .down ? "Not using nice-dns" : "Asks",
                          tone: comp == .ok ? .neutral : comp, captionChanged: comp == .down, dashedIn: false))
    for (id, label, caption) in [(PathNodeID.pihole, "Pi-hole", "Blocks ads"), (.unbound, "Unbound", "Resolves")] {
        let t = nodeTone(id)
        let (c, ch) = changed(t, caption)
        nodes.append(PathNode(id: id, label: label, caption: c, tone: t, captionChanged: ch, dashedIn: false))
    }
    let tor = nodeTone(.tor)
    let bridgeCaption: String
    switch (s.bridges.mode, s.bridges.count) {
    case ("off", _): bridgeCaption = "No bridges"
    case (_, let n?): bridgeCaption = "\(n) \(plural(Int(n), "bridge", "bridges"))"
    default: bridgeCaption = "Bridges"
    }
    let (torCaption, torChanged) = changed(tor, bridgeCaption)
    nodes.append(PathNode(id: .tor, label: "Tor", caption: torCaption, tone: tor, captionChanged: torChanged, dashedIn: false))

    var res: Tone = .neutral
    if let o = selectedObs {
        res = tone(Checks.state(of: o))
    } else if !routes.isEmpty && routes.allSatisfy({ $0.verdict == "unhealthy" }) {
        res = .down
    }
    if let t = s.obs.first(where: { $0.name == "route-table" }).map({ tone(Checks.state(of: $0)) }), t != .ok {
        res = worst([res, t])
    }
    if backup && res != .down { res = .attention }
    if old { res = .neutral }
    let label = selected.map(routeProvider) ?? "Resolver"
    var caption = selected.map(routeCaption) ?? "Not selected yet"
    var captionChanged = false
    if exitBackup && !old {
        caption = selected == "cloudflare-legacy" ? "Backup: legacy port" : "Backup: Tor exit"
        captionChanged = true
    } else if res == .down {
        (caption, captionChanged) = ("Not answering", true)
    }
    nodes.append(PathNode(id: .resolver, label: label, caption: caption, tone: res, captionChanged: captionChanged,
                          dashedIn: exitBackup && !old))

    let footer: String
    if let sel = selected {
        let name = routeName(sel)
        let ready = routes.filter { $0.name != "route:\(sel)" && $0.verdict == "healthy" }.count
        let backups = ready == 1 ? "1 backup route is ready." : "\(ready) backup routes are ready."
        if let o = selectedObs, o.verdict == "healthy" {
            if let ms = o.ms {
                footer = "Answered in \(String(format: "%.1f", Double(ms) / 1000)) s on the \(name) route. \(backups)"
            } else {
                footer = "Answered on the \(name) route. \(backups)"
            }
        } else if selectedObs != nil {
            footer = "The \(name) route is selected but not answering. \(backups)"
        } else {
            footer = "The \(name) route is selected. \(backups)"
        }
    } else {
        footer = "No route selected yet."
    }
    return LookupPath(nodes: nodes, footer: footer)
}

/// The panel's one-line path: "Pi-hole › Unbound › Tor › Cloudflare onion".
public func pathLine(_ s: Status) -> String {
    pathParts(s).joined(separator: " › ")
}

/// The words of the panel's path line, one per hop.
public func pathParts(_ s: Status) -> [String] {
    ["Pi-hole", "Unbound", "Tor", s.route.map { routeName($0.id) } ?? "no route yet"]
}

// MARK: Attention list and Checks

/// One failing check on Overview: icon by level, the headline from the check
/// table, the raw reason under it.
public struct AttentionRow: Equatable {
    public var id: String
    public var tone: Tone
    public var headline: String
    public var reason: String

    public init(id: String, tone: Tone, headline: String, reason: String) {
        self.id = id
        self.tone = tone
        self.headline = headline
        self.reason = reason
    }
}

/// The checks that are not healthy, a down one before an attention one.
public func attentionRows(_ s: Status) -> [AttentionRow] {
    let rows = notHealthy(s).map { o -> AttentionRow in
        AttentionRow(id: o.name, tone: tone(Checks.state(of: o)), headline: Checks.resolve(o.name).headline, reason: o.reason)
    }
    return rows.filter { $0.tone == .down } + rows.filter { $0.tone != .down }
}

/// "14 of 15 checks passing" or "1 of 15 checks need attention".
public func checksTitle(_ s: Status) -> String {
    let total = s.obs.count
    if total == 0 { return "No checks recorded yet" }
    let bad = notHealthy(s).count
    if bad == 0 { return "\(total) of \(total) checks passing" }
    return "\(bad) of \(total) checks need attention"
}

public func checksSubtitle(_ s: Status, now: UInt64) -> String {
    lastPassAgo(s, now: now).map { "Last pass \($0)." } ?? "No pass yet."
}

/// Overview's links, shown at level ok: the passing count and the newest repair.
public func overviewLinks(_ s: Status, now: UInt64) -> (passing: String, repair: String?) {
    let passing = checksTitle(s)
    guard let r = repairRows(s, now: now).first else { return (passing, nil) }
    return (passing, "Last repair \(r.ago) · \(r.text)")
}

public struct CheckRowModel: Equatable {
    public var id: String
    public var name: String
    public var tone: Tone
    public var healthy: Bool
    /// The headline of a failing row.
    public var headline: String?
    /// The short value at the end of a row: a route's seconds, the owner, the count of containers.
    public var value: String?
    /// The selected route's pill.
    public var inUse: Bool
    /// `{id} · {verdict} · {ms} ms`.
    public var record: String
    public var reason: String
}

public struct CheckGroupModel: Equatable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var rows: [CheckRowModel]
    public var passing: Int
    public var failing: Int
    public var unclear: Int
    /// "{n} passing", "{n} failing" or "{n} unclear".
    public var summary: String
    public var summaryTone: Tone
    /// A group with a check that is not healthy starts expanded.
    public var startsExpanded: Bool
}

/// The ids of the groups, in the order they are drawn.
public let checkGroupIDs = ["this-computer", "services", "routes", "other"]

func shortened(_ s: String, _ limit: Int) -> String {
    s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
}

/// The checks in three groups plus Other (only when a name is unknown).
public func checkGroups(_ s: Status) -> [CheckGroupModel] {
    let selected = s.route?.id
    func model(_ o: Obs) -> CheckRowModel {
        let info = Checks.resolve(o.name)
        let state = Checks.state(of: o)
        var value: String?
        if state == .healthy {
            if info.group == "routes", let ms = o.ms {
                value = String(format: "%.1f s", Double(ms) / 1000)
            } else if o.name == "dns-owner" {
                value = shortened(o.reason, 36)
            } else if o.name == "runtime", let list = o.reason.components(separatedBy: ": ").dropFirst().first {
                let n = list.split(separator: " ").count
                if n > 0 { value = "\(n) \(plural(n, "container", "containers"))" }
            }
        } else if info.group == "routes", let ms = o.ms, o.verdict != "unhealthy" {
            value = String(format: "%.1f s", Double(ms) / 1000)
        }
        return CheckRowModel(
            id: o.name, name: info.name, tone: tone(state), healthy: state == .healthy,
            headline: state == .healthy ? nil : info.headline, value: value,
            inUse: o.name == selected.map { "route:\($0)" },
            record: ([o.name, o.verdict] + (o.ms.map { ["\($0) ms"] } ?? [])).joined(separator: " · "),
            reason: o.reason)
    }
    var out: [CheckGroupModel] = []
    for gid in checkGroupIDs {
        let obs = s.obs.filter { Checks.resolve($0.name).group == gid }
        if obs.isEmpty && gid == "other" { continue }
        let rows = obs.map(model)
        let sorted = rows.filter { !$0.healthy } + rows.filter { $0.healthy }
        let failing = obs.filter { $0.verdict == "unhealthy" }.count
        let unclear = obs.filter { $0.verdict != "healthy" && $0.verdict != "unhealthy" }.count
        let passing = rows.filter(\.healthy).count
        let title: String
        var subtitle: String
        switch gid {
        case "this-computer":
            title = "This computer"
            subtitle = "System DNS, local answers, ad blocking, cache, install record"
        case "services":
            title = "Services"
            subtitle = "Pi-hole, Unbound, Tor proxy (\(s.install.variant ?? "unknown")), container runtime"
        case "routes":
            title = "Routes through Tor"
            subtitle = "Four ways out. One is in use, the others are backups."
        default:
            title = "Other"
            subtitle = "Checks this version of the window does not know"
        }
        let summary: String
        let sumTone: Tone
        if failing > 0 {
            summary = "\(failing) failing"
            sumTone = rows.contains { !$0.healthy && $0.tone == .down } ? .down : .attention
        } else if unclear > 0 {
            summary = "\(unclear) unclear"
            sumTone = .attention
        } else {
            summary = "\(passing) passing"
            sumTone = .ok
        }
        out.append(CheckGroupModel(id: gid, title: title, subtitle: subtitle, rows: sorted, passing: passing, failing: failing,
                                   unclear: unclear, summary: summary, summaryTone: sumTone, startsExpanded: failing + unclear > 0))
    }
    return out
}

// MARK: Automatic repairs

public struct RepairRow: Equatable {
    public var text: String
    public var ago: String
    public var epoch: UInt64?
}

/// The journal's `recent` rows (oldest first) as at most five lines, newest
/// first. The `requested`, `acknowledged` and `ready` steps of one target
/// make one line that shows the latest step; a `ready` ends the line, so the
/// same target moved again later is a line of its own.
public func repairRows(_ s: Status, now: UInt64) -> [RepairRow] {
    struct Group { var target: String; var latest: Recent }
    var groups: [Group] = []
    var open: Set<String> = []
    for r in s.recent {
        if open.contains(r.target), let i = groups.lastIndex(where: { $0.target == r.target }) {
            groups[i].latest = r
        } else {
            groups.append(Group(target: r.target, latest: r))
            open.insert(r.target)
        }
        if r.result == "ready" { open.remove(r.target) }
    }
    var rows: [RepairRow] = []
    var routeMoves: [String] = []
    let lastBridges = groups.lastIndex { $0.target == "bridges" }
    for (idx, g) in groups.enumerated() {
        var text: String
        if g.target.hasPrefix("route:") {
            let id = String(g.target.dropFirst("route:".count))
            let after = routeMoves.last
            if id == "cloudflare-onion", let a = after, a.hasSuffix("-exit") {
                text = "Moved back to the \(routeName(id)) route"
            } else {
                text = "Moved to the \(routeName(id)) route"
            }
            routeMoves.append(id)
        } else if g.target == "bridges" {
            // The journal does not say which way, so only the newest line can name the mode `status` reports now.
            if idx == lastBridges, let m = s.bridges.mode { text = "Bridges turned \(m)" } else { text = "Bridges changed" }
        } else if let n = restartedName(g.target) {
            text = "Restarted \(n)"
        } else {
            text = g.target
        }
        if g.latest.result != "ready" { text += " (in progress)" }
        rows.append(RepairRow(text: text, ago: g.latest.epoch.map { ago($0, now: now) } ?? "unknown", epoch: g.latest.epoch))
    }
    return Array(rows.reversed().prefix(5))
}

/// The friendly name of a container or service the journal says was restarted.
func restartedName(_ target: String) -> String? {
    let id = target.hasPrefix("container:") ? String(target.dropFirst("container:".count)) : target
    if id.hasPrefix("tor-") && Checks.info("container:\(id)") != nil { return "Tor proxy" }
    if let i = Checks.info("container:\(id)") { return i.name }
    if id == "tor" || id == "proxy" { return "Tor proxy" }
    return nil
}

// MARK: Controls

/// Overview's Tor bridges row subtitle.
public func bridgesSubtitle(on: Bool) -> String {
    on ? "Hides Tor use from your internet provider. Switching restarts Tor, about a minute."
       : "Off. Your provider can see that Tor is in use. Switching restarts Tor, about a minute."
}

/// The cost line under the panel's bridges switch.
public let bridgesCostLine = "Switching restarts Tor, about a minute"

/// The switch row's tooltip.
public func bridgesTooltip(_ s: Status, now: UInt64) -> String {
    switch s.bridges.lastRefresh {
    case .at(let e)?: return "Bridges last refreshed \(ago(e, now: now))"
    case .never?: return "Bridges have not been refreshed yet"
    case nil: return ""
    }
}

/// The Pi-hole admin row's subtitle: the URL without its scheme.
public func adminSubtitle(_ s: Status) -> String {
    guard let u = s.admin.url, !u.isEmpty else { return "Blocklists and query log" }
    let bare = u.components(separatedBy: "://").last ?? u
    return "Blocklists and query log at \(bare)"
}

/// The automatic-checks switch's subtitle.
public func autoChecksSubtitle(_ s: Status) -> String {
    s.controller.mode == "shadow"
        ? "Shadow mode: checks run, repairs do not."
        : "Runs on a schedule and repairs what it can. Also looks for updates twice a day."
}

/// The automatic-checks switch: on when the schedule is loaded.
public func autoChecksOn(_ s: Status) -> Bool { s.controller.schedule == "loaded" }

// MARK: Update row

public enum UpdateButton: Equatable {
    /// "Check for Update" (`update-check`).
    case check
    /// "Install…" (`update`).
    case install
}

/// The update row: one component, drawn in Overview and in Setup.
public struct UpdateRowText: Equatable {
    public var title: String
    public var subtitle: String?
    public var button: UpdateButton
    /// The commit named in the subtitle, drawn in monospace.
    public var commit: String?

    public init(title: String, subtitle: String?, button: UpdateButton, commit: String?) {
        self.title = title
        self.subtitle = subtitle
        self.button = button
        self.commit = commit
    }
}

public func updateRowText(_ s: Status, now: UInt64) -> UpdateRowText {
    let u = s.update
    let branch = s.install.branch
    let checked = u.checkedAt.map { ago($0, now: now) }
    let twice = u.auto == "stopped" ? "" : " nice-dns checks twice a day."
    switch u.result {
    case .current?:
        let lead: String
        switch (branch, checked) {
        case (let b?, let c?): lead = "Branch \(b), checked \(c)."
        case (let b?, nil): lead = "Branch \(b)."
        case (nil, let c?): lead = "Checked \(c)."
        case (nil, nil): lead = ""
        }
        return UpdateRowText(title: "Up to date", subtitle: (lead + twice).trimmingCharacters(in: .whitespaces), button: .check, commit: nil)
    case .available?:
        let commit = u.remoteCommit.map(shortCommit)
        let found = checked.map { ", found \($0)" } ?? ""
        let sub: String
        switch (branch, commit) {
        case (let b?, let c?): sub = "Branch \(b) is now at \(c)\(found)."
        case (nil, let c?): sub = "The branch is now at \(c)\(found)."
        case (let b?, nil): sub = "Branch \(b) has a different version\(found)."
        case (nil, nil): sub = "The branch has a different version\(found)."
        }
        return UpdateRowText(title: "Update available", subtitle: sub, button: .install, commit: commit)
    default:
        if u.neverChecked { return UpdateRowText(title: "Not checked yet", subtitle: nil, button: .check, commit: nil) }
        return UpdateRowText(title: "Could not check for updates", subtitle: checked.map { "Last tried \($0)." },
                             button: .check, commit: nil)
    }
}

// MARK: Setup

private let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

/// "9 November 2026" from a generation id like `20261109T180318Z-nogit0000000`; nil when it has no date.
public func generationDate(_ generation: String?) -> String? {
    guard let g = generation, g.count >= 8 else { return nil }
    let d = Array(g.prefix(8))
    guard d.allSatisfy(\.isNumber), let y = Int(String(d[0..<4])), let m = Int(String(d[4..<6])), let day = Int(String(d[6..<8])),
          (1...12).contains(m), (1...31).contains(day) else { return nil }
    return "\(day) \(monthNames[m - 1]) \(y)"
}

/// Setup > Version: "Installed {date}" and "Branch {branch} at {12 hex}".
public func versionRow(_ s: Status) -> (title: String, subtitle: String) {
    (versionRowParts(s).title, versionRowParts(s).subtitle)
}

/// The version row with the commit it names, which the window draws in monospace.
public func versionRowParts(_ s: Status) -> (title: String, subtitle: String, commit: String?) {
    let title = generationDate(s.install.generation).map { "Installed \($0)" } ?? "Installed"
    let branch = s.install.branch ?? "unknown"
    var sub = "Branch \(branch)"
    var commit: String?
    if let c = s.install.sourceCommit, c != "unknown", !c.isEmpty { commit = shortCommit(c); sub += " at \(shortCommit(c))" }
    else { sub += ", source commit unknown" }
    return (title, sub, commit)
}

/// The text "Copy build details" puts on the pasteboard.
public func buildDetails(_ s: Status) -> String {
    let i = s.install
    return [
        "generation: \(i.generation ?? "unknown")",
        "source commit: \(i.sourceCommit ?? "unknown")",
        "branch: \(i.branch ?? "unknown")",
        "proxy: \(i.variant ?? "unknown")",
        "pi-hole image: \(i.pihole ?? "unknown")",
        "platform: \(i.platform ?? "unknown")",
        "lock: \(i.lock ?? "unknown")",
        "helper: \(s.helper.version ?? "unknown")",
    ].joined(separator: "\n") + "\n"
}

/// Setup shows the "Root helper is missing" row only then.
public func helperMissing(_ s: Status) -> Bool { s.helper.installed == false }

// MARK: Action bar

/// The present-tense title of a running action.
public func runningTitle(_ id: String) -> String {
    if let p = StackChoice.choice(of: id) {
        return p.selector.kind == .proxy ? "Switching the Tor proxy to \(p.choice)" : "Switching Pi-hole to \(p.choice)"
    }
    switch id {
    case "bridges-on": return "Turning Tor bridges on"
    case "bridges-off": return "Turning Tor bridges off"
    case "restart": return "Restarting the stack"
    case "reinstall": return "Reinstalling nice-dns"
    case "uninstall": return "Uninstalling nice-dns"
    case "install": return "Installing nice-dns"
    case "update": return "Installing the update"
    case "update-check": return "Checking for updates"
    case "health-start": return "Turning on automatic checks"
    case "health-stop": return "Turning off automatic checks"
    case "health-run": return "Running checks"
    case "failures": return "Reading recent failures"
    default: return Actions.lookup(id)?.label ?? id
    }
}

/// The title of a finished action: the action's own last line where the
/// contract defines one, else "{label}: finished".
public func resultTitle(_ id: String, lines: [String]) -> String {
    let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?.trimmingCharacters(in: .whitespaces)
    if let l = last {
        if (id == "bridges-on" || id == "bridges-off") && l.hasPrefix("Bridges are") { return l }
        if id == "update" && l.hasPrefix("updated to") { return l }
        if id == "update-check" && l == "current" { return l }
        if StackChoice.choice(of: id) != nil && l.hasPrefix("Switched:") { return l }
    }
    return "\(Actions.lookup(id)?.label ?? id): finished"
}

/// "{label} did not finish", with the sentence-case label the window's own buttons use.
public func failedTitle(_ id: String) -> String {
    let label: String
    switch id {
    case "install": label = "Install"
    case "reinstall": label = "Reinstall"
    case "restart": label = "Restart"
    case "uninstall": label = "Uninstall"
    case "update-check": label = "Check for update"
    case "update": label = "Update"
    case "health-run": label = "Run checks"
    case "failures": label = "Show failures"
    default: label = runningTitle(id)
    }
    return "\(label) did not finish"
}

/// A time taken: "12 s", "2 min 48 s", "1 h 5 min" (as the Linux bar says it).
public func elapsedText(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s < 60 { return "\(s) s" }
    if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
    return (s % 3600) / 60 == 0 ? "\(s / 3600) h" : "\(s / 3600) h \((s % 3600) / 60) min"
}
