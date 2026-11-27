//! The status level and everything the window says about it (SPEC 3, 4, 5.3,
//! 5.4): the hero copy, the five lookup-path nodes and their footer, the
//! attention rows, the update row, the check groups and the repair lines. Every
//! item is a pure function of `model::Status` (and the clock), with no GTK, so
//! the tests run with no display and the hero, the path and the Checks badge
//! can never disagree.
//!
//! Friendly names, groups and the severity of an unhealthy check come from
//! `gui/share/checks.tsv`, compiled in like the action table.

use std::sync::OnceLock;

use crate::model::{Moment, Obs, Recent, Stale, Status, UpdateResult, View};

const TABLE: &str = include_str!("../../share/checks.tsv");

// ----------------------------------------------------------------- the table

/// Which of the three Checks groups a check is in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupKind {
    ThisComputer,
    Services,
    Routes,
    Other,
}

impl GroupKind {
    pub const ALL: [GroupKind; 4] = [GroupKind::ThisComputer, GroupKind::Services, GroupKind::Routes, GroupKind::Other];

    fn parse(v: &str) -> Option<GroupKind> {
        match v {
            "this-computer" => Some(GroupKind::ThisComputer),
            "services" => Some(GroupKind::Services),
            "routes" => Some(GroupKind::Routes),
            "other" => Some(GroupKind::Other),
            _ => None,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            GroupKind::ThisComputer => "This computer",
            GroupKind::Services => "Services",
            GroupKind::Routes => "Routes through Tor",
            GroupKind::Other => "Other",
        }
    }
}

/// One of the five nodes of the lookup path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeId {
    Computer,
    Pihole,
    Unbound,
    Tor,
    Resolver,
}

impl NodeId {
    pub const ALL: [NodeId; 5] = [NodeId::Computer, NodeId::Pihole, NodeId::Unbound, NodeId::Tor, NodeId::Resolver];

    fn parse(v: &str) -> Option<NodeId> {
        match v {
            "computer" => Some(NodeId::Computer),
            "pihole" => Some(NodeId::Pihole),
            "unbound" => Some(NodeId::Unbound),
            "tor" => Some(NodeId::Tor),
            "resolver" => Some(NodeId::Resolver),
            _ => None,
        }
    }
}

/// How bad an unhealthy check is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Severity {
    Healthy,
    Attention,
    Down,
}

/// A row of `checks.tsv`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckDef {
    pub id: &'static str,
    pub group: GroupKind,
    pub name: &'static str,
    pub node: Option<NodeId>,
    pub when_unhealthy: Severity,
    pub headline: &'static str,
    pub value: &'static str,
}

fn parse_table(text: &'static str) -> Result<Vec<CheckDef>, String> {
    let mut out = Vec::new();
    for (i, line) in text.lines().enumerate().skip(1) {
        let n = i + 1;
        if line.is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() != 8 {
            return Err(format!("line {n}: {} fields, not 8", f.len()));
        }
        let group = GroupKind::parse(f[1]).ok_or_else(|| format!("line {n}: unknown group '{}'", f[1]))?;
        let node = match f[3] {
            "" => None,
            v => Some(NodeId::parse(v).ok_or_else(|| format!("line {n}: unknown path node '{v}'"))?),
        };
        let when_unhealthy = match f[4] {
            "down" => Severity::Down,
            "attention" => Severity::Attention,
            v => return Err(format!("line {n}: level_when_unhealthy is '{v}'")),
        };
        out.push(CheckDef { id: f[0], group, name: f[2], node, when_unhealthy, headline: f[5], value: f[6] });
    }
    if !out.iter().any(|d| d.id == "*") {
        return Err("no '*' row for names the table does not list".into());
    }
    Ok(out)
}

fn table() -> &'static [CheckDef] {
    static CHECKS: OnceLock<Vec<CheckDef>> = OnceLock::new();
    CHECKS.get_or_init(|| parse_table(TABLE).expect("gui/share/checks.tsv is well-formed"))
}

/// The table row for observation `name`, if it is listed (not the `*` row).
pub fn known(name: &str) -> Option<&'static CheckDef> {
    table().iter().find(|d| d.id == name && d.id != "*")
}

fn wildcard() -> &'static CheckDef {
    table().iter().find(|d| d.id == "*").expect("checked at load")
}

/// What the window knows of one observation, listed or not.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub group: GroupKind,
    pub name: String,
    pub node: Option<NodeId>,
    pub when_unhealthy: Severity,
    pub headline: String,
    pub listed: bool,
    value: &'static str,
}

fn resolve(name: &str) -> Resolved {
    match known(name) {
        Some(d) => Resolved {
            group: d.group,
            name: d.name.to_string(),
            node: d.node,
            when_unhealthy: d.when_unhealthy,
            headline: d.headline.to_string(),
            listed: true,
            value: d.value,
        },
        None => {
            // A name this version does not know goes to "Other" with its raw id.
            let w = wildcard();
            Resolved {
                group: w.group,
                name: name.to_string(),
                node: None,
                when_unhealthy: w.when_unhealthy,
                headline: format!("{name}: check failed"),
                listed: false,
                value: "",
            }
        }
    }
}

// ---------------------------------------------------------------------- time

/// `epoch` said as a time before `now`: "just now", "5 min ago", "3 h ago".
pub fn ago(epoch: u64, now: u64) -> String {
    if epoch > now {
        return "in the future".into();
    }
    match now - epoch {
        s if s < 60 => "just now".into(),
        s if s < 3600 => format!("{} min ago", s / 60),
        s if s < 86_400 => format!("{} h ago", s / 3600),
        s => format!("{} days ago", s / 86_400),
    }
}

/// The first 12 characters of a commit.
pub fn short(sha: &str) -> &str {
    sha.get(..12).unwrap_or(sha)
}

// --------------------------------------------------------------------- level

/// The one answer to "is my DNS protected?" (SPEC 3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Error,
    NotInstalled,
    Waiting,
    Stale,
    Down,
    Attention,
    Ok,
}

/// The colour family a level, a node or a row is drawn in. Colour never
/// carries status alone: each also has its own icon and words.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tint {
    Ok,
    Attention,
    Down,
    Neutral,
}

impl Level {
    /// The level of what the status command said, for the pages that are not
    /// an installed status.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn of_view(v: &View) -> Level {
        match v {
            View::Installed(s) | View::Unreadable(s) => level(s),
            View::NotInstalled { .. } => Level::NotInstalled,
            View::Error(_) => Level::Error,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Level::Error => "error",
            Level::NotInstalled => "not-installed",
            Level::Waiting => "waiting",
            Level::Stale => "stale",
            Level::Down => "down",
            Level::Attention => "attention",
            Level::Ok => "ok",
        }
    }

    /// The results are old: the path is neutral and the rows are dimmed.
    pub fn old_results(self) -> bool {
        matches!(self, Level::Waiting | Level::Stale)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Health {
    Healthy,
    Unhealthy,
    Indeterminate,
}

fn health(o: &Obs) -> Health {
    match o.verdict.as_str() {
        "healthy" => Health::Healthy,
        "unhealthy" => Health::Unhealthy,
        _ => Health::Indeterminate,
    }
}

fn severity(o: &Obs) -> Severity {
    match health(o) {
        Health::Healthy => Severity::Healthy,
        Health::Unhealthy => resolve(&o.name).when_unhealthy,
        Health::Indeterminate => Severity::Attention,
    }
}

fn routes(s: &Status) -> impl Iterator<Item = &Obs> {
    s.obs.iter().filter(|o| o.name.starts_with("route:"))
}

fn no_route_answers(s: &Status) -> bool {
    routes(s).next().is_some() && routes(s).all(|o| health(o) == Health::Unhealthy)
}

fn verdict_fails_the_chain(s: &Status) -> bool {
    // `FAIL [chain-resolves]`: the chain itself did not answer. An
    // INDETERMINATE verdict is no known failure.
    s.controller.verdict.as_deref().is_some_and(|v| v.starts_with("FAIL") && v.contains("chain-resolves"))
}

/// The level of an installed status; first match wins (SPEC 3).
pub fn level(s: &Status) -> Level {
    match s.controller.stale {
        Some(Stale::Never) => return Level::Waiting,
        Some(Stale::Seconds(_) | Stale::Future) => return Level::Stale,
        Some(Stale::No) | None => {}
    }
    if s.obs.iter().any(|o| severity(o) == Severity::Down) || verdict_fails_the_chain(s) || no_route_answers(s) {
        return Level::Down;
    }
    if s.obs.iter().any(|o| health(o) != Health::Healthy)
        || s.controller.verdict.as_deref() != Some("OK")
        || !s.unreadable.is_empty()
    {
        return Level::Attention;
    }
    Level::Ok
}

// ----------------------------------------------------------------- the checks

/// One observation as the window lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckRow {
    pub id: String,
    pub name: String,
    pub severity: Severity,
    /// Unhealthy, as against indeterminate.
    pub failing: bool,
    pub headline: String,
    pub reason: String,
    /// The short value at the end of the row: seconds for routes.
    pub value: String,
    /// The selected route.
    pub in_use: bool,
    /// `{id} · {verdict} · {ms} ms`, then the full reason.
    pub record: String,
}

fn seconds(ms: u64) -> String {
    format!("{:.1} s", ms as f64 / 1000.0)
}

fn row(s: &Status, o: &Obs) -> CheckRow {
    let r = resolve(&o.name);
    let value = match r.value {
        v if v.starts_with("obs ms") => o.ms.map(seconds).unwrap_or_default(),
        v if v.starts_with("count of containers") => {
            let n = o.reason.strip_prefix("running:").map_or(0, |rest| rest.split_whitespace().count());
            if n > 0 { format!("{n} running") } else { String::new() }
        }
        v if v.starts_with("reason") => o.reason.clone(),
        _ => String::new(),
    };
    let head = match o.ms {
        Some(ms) => format!("{} · {} · {ms} ms", o.name, o.verdict),
        None => format!("{} · {}", o.name, o.verdict),
    };
    CheckRow {
        id: o.name.clone(),
        name: r.name,
        severity: severity(o),
        failing: health(o) == Health::Unhealthy,
        headline: r.headline,
        reason: o.reason.clone(),
        value,
        in_use: s.route.as_ref().is_some_and(|rt| o.name == format!("route:{}", rt.id)),
        record: format!("{head}\n{}", o.reason),
    }
}

/// The checks that are not healthy, worst first (down before attention, then
/// in the order the controller recorded them).
pub fn attention(s: &Status) -> Vec<CheckRow> {
    let mut rows: Vec<CheckRow> =
        s.obs.iter().filter(|o| health(o) != Health::Healthy).map(|o| row(s, o)).collect();
    rows.sort_by(|a, b| b.severity.cmp(&a.severity));
    rows
}

pub fn attention_title(n: usize) -> String {
    if n == 1 { "1 check needs attention".into() } else { format!("{n} checks need attention") }
}

/// One of the Checks view's expandable groups.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Group {
    pub kind: GroupKind,
    pub title: &'static str,
    pub subtitle: String,
    /// "5 passing", "1 failing" or "1 unclear".
    pub summary: String,
    pub worst: Severity,
    /// Failing rows first.
    pub rows: Vec<CheckRow>,
    /// Starts open: some check in it is not healthy.
    pub expanded: bool,
}

/// The groups with at least one check (the Other group only when it has any),
/// in the order of SPEC 5.3.
pub fn groups(s: &Status) -> Vec<Group> {
    let mut out = Vec::new();
    for kind in GroupKind::ALL {
        let mut rows: Vec<CheckRow> = s.obs.iter().filter(|o| resolve(&o.name).group == kind).map(|o| row(s, o)).collect();
        if rows.is_empty() {
            continue;
        }
        // Failing first, then unclear, then passing; stable inside each.
        rows.sort_by_key(|r| match (r.failing, r.severity) {
            (true, _) => 0,
            (false, Severity::Healthy) => 2,
            (false, _) => 1,
        });
        let passing = rows.iter().filter(|r| r.severity == Severity::Healthy).count();
        let failing = rows.iter().filter(|r| r.failing).count();
        let unclear = rows.len() - passing - failing;
        let summary = if failing > 0 {
            format!("{failing} failing")
        } else if unclear > 0 {
            format!("{unclear} unclear")
        } else {
            format!("{passing} passing")
        };
        let subtitle = match kind {
            GroupKind::ThisComputer => "System DNS, local answers, ad blocking, cache, install record".to_string(),
            GroupKind::Services => match s.install.variant.as_deref() {
                Some(v) => format!("Pi-hole, Unbound, Tor proxy ({v}), container runtime"),
                None => "Pi-hole, Unbound, Tor proxy, container runtime".into(),
            },
            GroupKind::Routes => "Four ways out. One is in use, the others are backups.".into(),
            GroupKind::Other => "Checks this version of the window does not know".into(),
        };
        out.push(Group {
            kind,
            title: kind.title(),
            subtitle,
            summary,
            worst: rows.iter().map(|r| r.severity).max().unwrap_or(Severity::Healthy),
            expanded: passing != rows.len(),
            rows,
        });
    }
    out
}

/// The Checks view's header.
pub fn checks_title(s: &Status) -> String {
    let total = s.obs.len();
    let bad = s.obs.iter().filter(|o| health(o) != Health::Healthy).count();
    match (total, bad) {
        (0, _) => "No checks recorded yet".into(),
        (_, 0) => format!("{total} of {total} checks passing"),
        (_, n) => format!("{n} of {total} checks need attention"),
    }
}

pub fn checks_subtitle(s: &Status, now: u64) -> String {
    match s.controller.last_pass {
        Some(Moment::At(e)) => format!("Last pass {}.", ago(e, now)),
        _ => "No pass yet.".into(),
    }
}

// ----------------------------------------------------------------------- hero

/// The status header: the one place of `health-run` (with the schedule
/// stopped and the results old, its button turns the schedule on instead).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hero {
    pub tint: Tint,
    /// A symbolic icon of the bundled set.
    pub icon: &'static str,
    pub title: String,
    pub subtitle: String,
    pub action: HeroAction,
}

/// The status header's one button. Turn on is the automatic-checks switch's
/// setter: `health-start` keeps its one place there.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HeroAction {
    /// "Run checks" (`health-run`).
    RunChecks,
    /// "Turn on": the schedule is stopped.
    TurnOn,
}

impl HeroAction {
    pub fn label(self) -> &'static str {
        match self {
            HeroAction::RunChecks => "Run checks",
            HeroAction::TurnOn => "Turn on",
        }
    }
}

fn last_pass_ago(s: &Status, now: u64) -> Option<String> {
    match (s.controller.last_pass, s.controller.stale) {
        (Some(Moment::At(e)), _) => Some(ago(e, now)),
        (_, Some(Stale::Seconds(sec))) => Some(ago(now.saturating_sub(sec), now)),
        _ => None,
    }
}

fn onion_unhealthy_on_backup(s: &Status) -> bool {
    let onion = s.obs.iter().find(|o| o.name == "route:cloudflare-onion");
    let Some(sel) = &s.route else { return false };
    let selected = s.obs.iter().find(|o| o.name == format!("route:{}", sel.id));
    sel.id != "cloudflare-onion"
        && onion.is_some_and(|o| health(o) == Health::Unhealthy)
        && selected.is_some_and(|o| health(o) == Health::Healthy)
}

pub fn hero(s: &Status, level: Level, now: u64) -> Hero {
    let run = |tint, icon, title: &str, subtitle: String| Hero {
        tint,
        icon,
        title: title.to_string(),
        subtitle,
        action: HeroAction::RunChecks,
    };
    let checked = || match last_pass_ago(s, now) {
        Some(a) => format!("Checked {a}."),
        None => String::new(),
    };
    let bad: Vec<&Obs> = s.obs.iter().filter(|o| health(o) != Health::Healthy).collect();
    match level {
        Level::Ok => {
            let sub = match checked().as_str() {
                "" => "Every lookup leaves through Tor.".to_string(),
                c => format!("Every lookup leaves through Tor. {c}"),
            };
            run(Tint::Ok, "nice-dns-shield-check-symbolic", "DNS is protected", sub)
        }
        Level::Attention => {
            let only_filtering = bad.len() == 1 && bad[0].name == "filtering";
            if onion_unhealthy_on_backup(s) {
                run(
                    Tint::Attention,
                    "nice-dns-warning-symbolic",
                    "DNS works, on a backup route",
                    "The Cloudflare onion route is not answering. Lookups still leave through Tor.".into(),
                )
            } else if only_filtering {
                run(
                    Tint::Attention,
                    "nice-dns-warning-symbolic",
                    "DNS works, but ads are not blocked",
                    format!("Lookups still leave through Tor. {}", checked()).trim_end().to_string(),
                )
            } else if bad.is_empty() {
                // The verdict is not OK, or a file could not be read, but no
                // single check is to blame.
                let why = match (&s.controller.verdict, s.unreadable.is_empty()) {
                    (Some(v), _) if v != "OK" && v != "unknown" => format!("The controller said {v}."),
                    _ => "Some files could not be read.".to_string(),
                };
                run(
                    Tint::Attention,
                    "nice-dns-warning-symbolic",
                    "DNS works, but the last check was not clean",
                    format!("{why} {}", checked()).trim_end().to_string(),
                )
            } else {
                let n = bad.len();
                let title = if n == 1 { "DNS works, 1 check needs attention".to_string() } else { format!("DNS works, {n} checks need attention") };
                Hero { title, ..run(Tint::Attention, "nice-dns-warning-symbolic", "", checked()) }
            }
        }
        Level::Stale => {
            let when = match s.controller.stale {
                Some(Stale::Future) => None,
                _ => last_pass_ago(s, now),
            };
            if s.controller.schedule.as_deref() == Some("stopped") {
                Hero {
                    action: HeroAction::TurnOn,
                    ..run(
                        Tint::Attention,
                        "nice-dns-warning-symbolic",
                        "Automatic checks are off",
                        match when {
                            Some(a) => format!("The last check ran {a}."),
                            None => "The last check is dated in the future.".into(),
                        },
                    )
                }
            } else {
                run(
                    Tint::Attention,
                    "nice-dns-warning-symbolic",
                    "Status is out of date",
                    match when {
                        Some(a) => format!("The last check ran {a}. Checks are overdue."),
                        None => "The last check is dated in the future. Checks are overdue.".into(),
                    },
                )
            }
        }
        Level::Waiting => run(
            Tint::Neutral,
            "nice-dns-shield-symbolic",
            "Waiting for the first check",
            "nice-dns has not checked this install yet.".into(),
        ),
        Level::Down => {
            let owner = s.obs.iter().find(|o| o.name == "dns-owner" && health(o) == Health::Unhealthy);
            if let Some(o) = owner {
                run(Tint::Down, "nice-dns-warning-symbolic", "This computer is not using nice-dns", o.reason.clone())
            } else if no_route_answers(s) {
                run(Tint::Down, "nice-dns-warning-symbolic", "DNS is down", "No route through Tor is answering.".into())
            } else {
                let first = s.obs.iter().find(|o| severity(o) == Severity::Down);
                let sub = match first {
                    Some(o) => resolve(&o.name).headline,
                    None => "The lookup chain is not resolving.".into(),
                };
                run(Tint::Down, "nice-dns-warning-symbolic", "DNS is down", sub)
            }
        }
        // Not installed statuses and errors have their own pages.
        Level::NotInstalled | Level::Error => {
            run(Tint::Neutral, "nice-dns-shield-symbolic", "nice-dns is not running", String::new())
        }
    }
}

// ------------------------------------------------------------------ the path

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeState {
    Ok,
    Attention,
    Down,
    Neutral,
}

impl NodeState {
    pub fn tint(self) -> Tint {
        match self {
            NodeState::Ok => Tint::Ok,
            NodeState::Attention => Tint::Attention,
            NodeState::Down => Tint::Down,
            NodeState::Neutral => Tint::Neutral,
        }
    }

    pub fn words(self) -> &'static str {
        match self {
            NodeState::Ok => "working",
            NodeState::Attention => "needs attention",
            NodeState::Down => "not working",
            NodeState::Neutral => "not checked",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Node {
    pub id: NodeId,
    pub icon: &'static str,
    pub label: String,
    pub caption: String,
    pub state: NodeState,
    /// The line into this node is dashed: a backup route is in use.
    pub dashed_in: bool,
}

fn provider(route: &str) -> &str {
    if route.starts_with("cloudflare") {
        "Cloudflare"
    } else if route.starts_with("quad9") {
        "Quad9"
    } else {
        route
    }
}

fn route_caption(route: &str) -> &'static str {
    match route {
        "cloudflare-onion" => "Onion resolver",
        "cloudflare-exit" | "quad9-exit" => "Via Tor exit",
        "cloudflare-legacy" => "Onion, legacy port",
        _ => "Resolver",
    }
}

fn route_name(id: &str) -> String {
    known(&format!("route:{id}")).map_or_else(|| id.to_string(), |d| d.name.to_string())
}

fn state_of(sev: impl Iterator<Item = Severity>) -> NodeState {
    let mut worst = None;
    for s in sev {
        worst = Some(worst.map_or(s, |w: Severity| w.max(s)));
    }
    match worst {
        None => NodeState::Neutral,
        Some(Severity::Healthy) => NodeState::Ok,
        Some(Severity::Attention) => NodeState::Attention,
        Some(Severity::Down) => NodeState::Down,
    }
}

/// The five nodes of "How a lookup travels", and the footer line.
pub fn path(s: &Status, level: Level) -> (Vec<Node>, String) {
    let selected = s.route.as_ref().map(|r| r.id.as_str());
    let on_backup = onion_unhealthy_on_backup(s) || {
        // The legacy port in use while the onion route fails is a backup too.
        selected.is_some_and(|sel| sel != "cloudflare-onion")
            && s.obs.iter().any(|o| o.name == "route:cloudflare-onion" && health(o) == Health::Unhealthy)
    };
    let mut nodes = Vec::new();
    for id in NodeId::ALL {
        let mut state = match id {
            NodeId::Resolver => {
                let sel_name = selected.map(|r| format!("route:{r}"));
                let mut st = state_of(
                    s.obs
                        .iter()
                        .filter(|o| o.name == "route-table" || Some(&o.name) == sel_name.as_ref())
                        .map(severity),
                );
                if no_route_answers(s) {
                    st = NodeState::Down;
                } else if on_backup && st == NodeState::Ok {
                    st = NodeState::Attention;
                }
                st
            }
            _ => state_of(s.obs.iter().filter(|o| resolve(&o.name).node == Some(id)).map(severity)),
        };
        if id == NodeId::Computer && state == NodeState::Ok {
            // The start of the path, not a service.
            state = NodeState::Neutral;
        }
        if level.old_results() {
            state = NodeState::Neutral;
        }
        let (icon, label, mut caption) = match id {
            NodeId::Computer => ("nice-dns-computer-symbolic", "This computer".to_string(), "Asks".to_string()),
            NodeId::Pihole => ("nice-dns-filter-symbolic", "Pi-hole".into(), "Blocks ads".into()),
            NodeId::Unbound => ("nice-dns-resolver-symbolic", "Unbound".into(), "Resolves".into()),
            NodeId::Tor => (
                "nice-dns-tor-symbolic",
                "Tor".into(),
                match (s.bridges.mode.as_deref(), s.bridges.count) {
                    (Some("off"), _) => "No bridges".into(),
                    (_, Some(1)) => "1 bridge".into(),
                    (_, Some(n)) => format!("{n} bridges"),
                    (_, None) => "Bridges".into(),
                },
            ),
            NodeId::Resolver => (
                "nice-dns-globe-symbolic",
                selected.map_or("Resolver", provider).to_string(),
                selected.map_or("Not selected yet", route_caption).to_string(),
            ),
        };
        let mut dashed_in = false;
        if id == NodeId::Resolver && on_backup && !level.old_results() {
            dashed_in = true;
            caption = match selected {
                Some("cloudflare-legacy") => "Backup: legacy port".into(),
                _ => "Backup: Tor exit".into(),
            };
        } else if matches!(state, NodeState::Attention | NodeState::Down) && id != NodeId::Resolver {
            caption = match (id, state) {
                (NodeId::Computer, NodeState::Down) => "Not using nice-dns".into(),
                (_, NodeState::Down) => "Not answering".into(),
                _ => "Needs attention".into(),
            };
        } else if id == NodeId::Resolver && state == NodeState::Down {
            caption = "Not answering".into();
        }
        nodes.push(Node { id, icon, label, caption, state, dashed_in });
    }
    (nodes, footer(s))
}

fn footer(s: &Status) -> String {
    let Some(sel) = &s.route else { return "No route selected yet.".into() };
    let name = route_name(&sel.id);
    let me = s.obs.iter().find(|o| o.name == format!("route:{}", sel.id));
    let backups = routes(s).filter(|o| o.name != format!("route:{}", sel.id) && health(o) == Health::Healthy).count();
    let ready = match backups {
        0 => "0 backup routes are ready.".to_string(),
        1 => "1 backup route is ready.".to_string(),
        k => format!("{k} backup routes are ready."),
    };
    match me {
        Some(o) if health(o) == Health::Healthy => match o.ms {
            Some(ms) => format!("Answered in {} on the {name} route. {ready}", seconds(ms)),
            None => format!("Answered on the {name} route. {ready}"),
        },
        Some(_) => format!("The {name} route is selected but not answering. {ready}"),
        None => format!("The {name} route is selected. {ready}"),
    }
}

/// The sentence read out for the whole path.
pub fn path_sentence(nodes: &[Node]) -> String {
    let parts: Vec<String> = nodes.iter().map(|n| format!("{} ({}, {})", n.label, n.caption, n.state.words())).collect();
    format!("How a lookup travels: {}", parts.join(", then "))
}

// ------------------------------------------------------------------- updates

/// The update row: one component, drawn in Overview and in Setup.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateRow {
    pub title: &'static str,
    pub subtitle: String,
    /// `update-check`, or `update` when one is available.
    pub button: &'static str,
    pub button_label: &'static str,
    pub suggested: bool,
}

pub fn update_row(s: &Status, now: u64) -> UpdateRow {
    let u = &s.update;
    let checked = u.checked_at.map(|t| ago(t, now));
    let branch = s.install.branch.as_deref();
    let twice = if u.auto.as_deref() == Some("stopped") { "" } else { " nice-dns checks twice a day." };
    let check = |title, subtitle: String| UpdateRow {
        title,
        subtitle,
        button: "update-check",
        button_label: "Check for update",
        suggested: false,
    };
    match (u.result, u.never_checked) {
        (_, true) => check("Not checked yet", String::new()),
        (Some(UpdateResult::Current), _) => {
            let lead = match (branch, &checked) {
                (Some(b), Some(c)) => format!("Branch {b}, checked {c}."),
                (Some(b), None) => format!("Branch {b}."),
                (None, Some(c)) => format!("Checked {c}."),
                (None, None) => String::new(),
            };
            check("Up to date", format!("{lead}{twice}").trim().to_string())
        }
        (Some(UpdateResult::Available), _) => {
            let at = u.remote_commit.as_deref().map(short);
            let found = checked.map(|c| format!(", found {c}")).unwrap_or_default();
            let subtitle = match (branch, at) {
                (Some(b), Some(c)) => format!("Branch {b} is now at {c}{found}."),
                (None, Some(c)) => format!("The branch is now at {c}{found}."),
                (Some(b), None) => format!("Branch {b} has a different version{found}."),
                (None, None) => format!("The branch has a different version{found}."),
            };
            UpdateRow {
                title: "Update available",
                subtitle,
                button: "update",
                button_label: "Install\u{2026}",
                suggested: true,
            }
        }
        _ => check("Could not check for updates", checked.map(|c| format!("Last tried {c}.")).unwrap_or_default()),
    }
}

// ------------------------------------------------------------------- repairs

/// One line of Automatic repairs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Repair {
    pub text: String,
    /// `{ago}` of the latest step, or empty.
    pub when: String,
}

fn restarted_name(target: &str) -> Option<String> {
    let id = target.strip_prefix("container:").unwrap_or(target);
    if let Some(d) = known(&format!("container:{id}")) {
        return Some(d.name.to_string());
    }
    match id {
        "tor" | "proxy" => Some("Tor proxy".into()),
        _ => None,
    }
}

/// The journal, collapsed per target and said in sentences: newest first, at
/// most five. A run of rows for one target (requested, acknowledged, ready)
/// is one line showing the latest step.
pub fn repairs(s: &Status, now: u64) -> Vec<Repair> {
    let mut runs: Vec<Vec<&Recent>> = Vec::new();
    for r in &s.recent {
        match runs.last_mut() {
            Some(run) if run[0].target == r.target => run.push(r),
            _ => runs.push(vec![r]),
        }
    }
    // The journal does not say which way, so only the newest line can name
    // the mode `status` reports now.
    let last_bridges = runs.iter().rposition(|r| r[0].target == "bridges");
    let mut out = Vec::new();
    for (i, run) in runs.iter().enumerate() {
        let latest = run[run.len() - 1];
        let target = latest.target.as_str();
        let mut text = if let Some(id) = target.strip_prefix("route:") {
            let after_exit = i > 0
                && runs[i - 1][0].target.starts_with("route:")
                && runs[i - 1][0].target != "route:cloudflare-onion";
            if id == "cloudflare-onion" && after_exit {
                format!("Moved back to the {} route", route_name(id))
            } else {
                format!("Moved to the {} route", route_name(id))
            }
        } else if target == "bridges" {
            match (Some(i) == last_bridges, s.bridges.mode.as_deref()) {
                (true, Some(m)) => format!("Bridges turned {m}"),
                _ => "Bridges changed".to_string(),
            }
        } else if let Some(n) = restarted_name(target) {
            format!("Restarted {n}")
        } else {
            target.to_string()
        };
        match latest.result.as_str() {
            "ready" => {}
            "requested" | "acknowledged" => text.push_str(" (in progress)"),
            other => text.push_str(&format!(" ({other})")),
        }
        out.push(Repair { text, when: latest.epoch.map(|e| ago(e, now)).unwrap_or_default() });
    }
    out.reverse();
    out.truncate(5);
    out
}

// --------------------------------------------------------------- small rows

/// "Last repair {ago} \u{b7} {newest repair sentence}", when there is one.
pub fn last_repair_link(repairs: &[Repair]) -> Option<String> {
    let r = repairs.first()?;
    let sentence = &r.text;
    if r.when.is_empty() {
        Some(format!("Last repair: {sentence}"))
    } else {
        Some(format!("Last repair {} \u{b7} {sentence}", r.when))
    }
}

/// The Tor bridges row's subtitle (SPEC 4.4).
pub fn bridges_subtitle(on: bool) -> &'static str {
    if on {
        "Hides Tor use from your internet provider. Switching restarts Tor, about a minute."
    } else {
        "Off. Your provider can see that Tor is in use. Switching restarts Tor, about a minute."
    }
}

/// "Bridges last refreshed {ago}", the switch row's tooltip.
pub fn bridges_tooltip(s: &Status, now: u64) -> Option<String> {
    match s.bridges.last_refresh? {
        Moment::At(e) => Some(format!("Bridges last refreshed {}", ago(e, now))),
        Moment::Never => Some("Bridges have not been refreshed yet".into()),
    }
}

/// "Blocklists and query log at {url without scheme}".
pub fn admin_subtitle(url: Option<&str>) -> String {
    match url {
        Some(u) => format!("Blocklists and query log at {}", u.split_once("://").map_or(u, |(_, rest)| rest)),
        None => "Blocklists and query log".into(),
    }
}

/// "9 November 2026" from a generation id that starts `YYYYMMDD`.
pub fn installed_on(generation: &str) -> Option<String> {
    const MONTHS: [&str; 12] =
        ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
    let d = generation.get(..8).filter(|d| d.bytes().all(|b| b.is_ascii_digit()))?;
    let (y, m, day): (u32, usize, u32) = (d[..4].parse().ok()?, d[4..6].parse().ok()?, d[6..].parse().ok()?);
    if !(1..=12).contains(&m) || !(1..=31).contains(&day) {
        return None;
    }
    Some(format!("{day} {} {y}", MONTHS[m - 1]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model;

    const NOW: u64 = 1_794_251_900;
    const INSTALLED: &str = include_str!("../../share/fixtures/status-installed.tsv");
    const STALE: &str = include_str!("../../share/fixtures/status-stale.tsv");
    const NOT_INSTALLED: &str = include_str!("../../share/fixtures/status-not-installed.tsv");
    const UPDATE: &str = include_str!("../../share/fixtures/status-update-available.tsv");

    fn st(text: &str) -> Status {
        model::parse(text).unwrap()
    }

    /// `INSTALLED` with the `obs` row of `name` given another verdict and reason.
    fn obs_is(text: &str, name: &str, verdict: &str, reason: &str) -> String {
        text.lines()
            .map(|l| {
                let f: Vec<&str> = l.split('\t').collect();
                if f.len() >= 5 && f[0] == "obs" && f[1] == name {
                    format!("obs\t{name}\t{verdict}\t{}\t{reason}\n", f[3])
                } else {
                    format!("{l}\n")
                }
            })
            .collect()
    }

    fn onion_down_exit_selected() -> String {
        obs_is(INSTALLED, "route:cloudflare-onion", "unhealthy", "no answer via tor-socat:18531 as tor.cloudflare-dns.com")
            .replacen("route\tselected\tcloudflare-onion\t73", "route\tselected\tcloudflare-exit\t74", 1)
    }

    // ------------------------------------------------------- the table

    #[test]
    fn checks_table_parses_and_has_the_wildcard() {
        let t = parse_table(TABLE).unwrap();
        assert_eq!(t.len(), 18);
        assert!(t.iter().any(|d| d.id == "*" && d.group == GroupKind::Other));
        assert_eq!(known("route:quad9-exit").unwrap().name, "Quad9 Tor exit");
        assert_eq!(known("dns-owner").unwrap().when_unhealthy, Severity::Down);
        assert_eq!(known("filtering").unwrap().when_unhealthy, Severity::Attention);
        assert!(known("*").is_none() && known("nope").is_none());
    }

    fn leak(s: String) -> &'static str {
        Box::leak(s.into_boxed_str())
    }

    #[test]
    fn checks_malformed_tables_are_refused() {
        let head = "id\tgroup\tname\tpath_node\tlevel_when_unhealthy\theadline_when_unhealthy\tvalue_when_healthy\tnotes\n";
        assert!(parse_table(leak(format!("{head}a\tservices\tA\t\tdown\th\t\n"))).unwrap_err().contains("7 fields"));
        assert!(parse_table(leak(format!("{head}a\tmoon\tA\t\tdown\th\t\t\n"))).unwrap_err().contains("group"));
        assert!(parse_table(leak(format!("{head}a\tservices\tA\tmoon\tdown\th\t\t\n"))).unwrap_err().contains("path node"));
        assert!(parse_table(leak(format!("{head}a\tservices\tA\t\tred\th\t\t\n"))).unwrap_err().contains("level_when_unhealthy"));
        assert!(parse_table(leak(format!("{head}a\tservices\tA\t\tdown\th\t\t\n"))).unwrap_err().contains("'*'"));
    }

    #[test]
    fn checks_every_observation_of_every_fixture_is_listed() {
        for (name, text) in [("installed", INSTALLED), ("stale", STALE), ("update", UPDATE), ("not-installed", NOT_INSTALLED)] {
            for o in &st(text).obs {
                assert!(known(&o.name).is_some(), "{name}: observation '{}' is not in checks.tsv", o.name);
                assert!(resolve(&o.name).listed);
            }
        }
    }

    #[test]
    fn checks_an_unknown_name_goes_to_other_with_its_raw_id() {
        let text = format!("{INSTALLED}obs\tfuture-probe\tunhealthy\t5\tsomething new\n");
        let s = st(&text);
        let g = groups(&s);
        let other = g.iter().find(|g| g.kind == GroupKind::Other).expect("an Other group");
        assert_eq!(other.rows.len(), 1);
        assert_eq!(other.rows[0].id, "future-probe");
        assert_eq!(other.rows[0].name, "future-probe");
        assert_eq!(other.rows[0].headline, "future-probe: check failed");
        assert_eq!(other.summary, "1 failing");
        assert!(other.expanded);
        // An unknown check is attention, never down.
        assert_eq!(level(&s), Level::Attention);
        // Without one there is no Other group.
        assert!(groups(&st(INSTALLED)).iter().all(|g| g.kind != GroupKind::Other));
    }

    // ------------------------------------------------------- the level

    #[test]
    fn level_table() {
        let cases: Vec<(&str, String, Level)> = vec![
            ("fresh and healthy", INSTALLED.into(), Level::Ok),
            ("stale 942 s", STALE.into(), Level::Stale),
            ("no pass yet", INSTALLED.replacen("controller\tstale\tno", "controller\tstale\tnever", 1), Level::Waiting),
            ("pass in the future", INSTALLED.replacen("controller\tstale\tno", "controller\tstale\tfuture", 1), Level::Stale),
            ("one backup route unhealthy", onion_down_exit_selected(), Level::Attention),
            (
                "filtering unhealthy",
                obs_is(INSTALLED, "filtering", "unhealthy", "doubleclick.net answered 1.2.3.4"),
                Level::Attention,
            ),
            ("an indeterminate check", obs_is(INSTALLED, "proxy", "indeterminate", "unreadable"), Level::Attention),
            ("dns-owner unhealthy", obs_is(INSTALLED, "dns-owner", "unhealthy", "/etc/resolv.conf: nameserver 9.9.9.9"), Level::Down),
            ("container down", obs_is(INSTALLED, "container:unbound", "unhealthy", "exited"), Level::Down),
            ("unbound down", obs_is(INSTALLED, "unbound", "unhealthy", "control: no answer"), Level::Down),
            ("verdict names chain-resolves", INSTALLED.replacen("controller\tverdict\tOK", "controller\tverdict\tFAIL [chain-resolves]", 1), Level::Down),
            ("verdict FAIL for a route only", INSTALLED.replacen("controller\tverdict\tOK", "controller\tverdict\tFAIL [route:cloudflare-onion]", 1), Level::Attention),
            ("verdict INDETERMINATE chain-resolves", INSTALLED.replacen("controller\tverdict\tOK", "controller\tverdict\tINDETERMINATE [chain-resolves]", 1), Level::Attention),
            ("unreadable rows", INSTALLED.replacen("bridges\tcount\t7\n", "bridges\tunreadable\t~/x: permission denied\n", 1), Level::Attention),
            ("verdict unknown", INSTALLED.replacen("controller\tverdict\tOK", "controller\tverdict\tunknown", 1), Level::Attention),
        ];
        for (what, text, want) in cases {
            assert_eq!(level(&st(&text)), want, "{what}");
        }
    }

    #[test]
    fn level_stale_and_waiting_win_over_a_failing_check() {
        let text = obs_is(STALE, "dns-owner", "unhealthy", "x");
        assert_eq!(level(&st(&text)), Level::Stale);
    }

    #[test]
    fn level_every_route_unhealthy_is_down() {
        let mut text = INSTALLED.to_string();
        for r in ["cloudflare-onion", "cloudflare-exit", "quad9-exit", "cloudflare-legacy"] {
            text = obs_is(&text, &format!("route:{r}"), "unhealthy", "no answer");
        }
        assert_eq!(level(&st(&text)), Level::Down);
        // Three of four is a backup-route problem, not an outage.
        let three = obs_is(&text, "route:quad9-exit", "healthy", "ok");
        assert_eq!(level(&st(&three)), Level::Attention);
    }

    #[test]
    fn level_pages_that_are_not_a_status() {
        assert_eq!(Level::of_view(&model::classify(Some(1), NOT_INSTALLED)), Level::NotInstalled);
        assert_eq!(Level::of_view(&model::classify(Some(2), "")), Level::Error);
        assert_eq!(Level::of_view(&model::classify(Some(0), INSTALLED)), Level::Ok);
        assert_eq!(Level::of_view(&model::classify(Some(0), STALE)), Level::Stale);
        for l in [Level::Error, Level::NotInstalled, Level::Waiting, Level::Stale, Level::Down, Level::Attention, Level::Ok] {
            assert!(!l.name().is_empty());
        }
    }

    // ------------------------------------------------------- the hero

    fn hero_of(text: &str) -> Hero {
        let s = st(text);
        hero(&s, level(&s), NOW)
    }

    #[test]
    fn hero_ok() {
        let h = hero_of(INSTALLED);
        assert_eq!((h.title.as_str(), h.tint, h.action), ("DNS is protected", Tint::Ok, HeroAction::RunChecks));
        assert_eq!(h.subtitle, "Every lookup leaves through Tor. Checked 1 min ago.");
        assert_eq!(h.action.label(), "Run checks");
    }

    #[test]
    fn hero_attention_variants() {
        let h = hero_of(&onion_down_exit_selected());
        assert_eq!(h.title, "DNS works, on a backup route");
        assert_eq!(h.subtitle, "The Cloudflare onion route is not answering. Lookups still leave through Tor.");
        assert_eq!(h.tint, Tint::Attention);

        let h = hero_of(&obs_is(INSTALLED, "filtering", "unhealthy", "x"));
        assert_eq!(h.title, "DNS works, but ads are not blocked");
        assert_eq!(h.subtitle, "Lookups still leave through Tor. Checked 1 min ago.");

        let h = hero_of(&obs_is(INSTALLED, "proxy", "indeterminate", "x"));
        assert_eq!(h.title, "DNS works, 1 check needs attention");
        assert_eq!(h.subtitle, "Checked 1 min ago.");

        let two = obs_is(&obs_is(INSTALLED, "proxy", "indeterminate", "x"), "local-cache", "unhealthy", "y");
        assert_eq!(hero_of(&two).title, "DNS works, 2 checks need attention");

        // The onion route failing while the onion route is selected is no backup.
        let h = hero_of(&obs_is(INSTALLED, "route:cloudflare-onion", "unhealthy", "x"));
        assert_eq!(h.title, "DNS works, 1 check needs attention");

        // No check to blame.
        let h = hero_of(&INSTALLED.replacen("controller\tverdict\tOK", "controller\tverdict\tINDETERMINATE []", 1));
        assert_eq!(h.title, "DNS works, but the last check was not clean");
        assert!(h.subtitle.starts_with("The controller said INDETERMINATE []."), "{}", h.subtitle);
    }

    #[test]
    fn hero_stale_and_waiting() {
        let h = hero_of(STALE);
        assert_eq!(h.title, "Status is out of date");
        assert_eq!(h.subtitle, "The last check ran 1 min ago. Checks are overdue.");
        assert_eq!(h.action, HeroAction::RunChecks);
        for s in [&h.title, &h.subtitle] {
            assert!(!s.contains("stale 942s"));
        }

        let stopped = STALE.replacen("controller\tschedule\tloaded", "controller\tschedule\tstopped", 1);
        let h = hero_of(&stopped);
        assert_eq!(h.title, "Automatic checks are off");
        assert_eq!(h.subtitle, "The last check ran 1 min ago.");
        assert_eq!((h.action, h.action.label()), (HeroAction::TurnOn, "Turn on"));

        let h = hero_of(&INSTALLED.replacen("controller\tstale\tno", "controller\tstale\tnever", 1));
        assert_eq!((h.title.as_str(), h.tint), ("Waiting for the first check", Tint::Neutral));
        assert_eq!(h.subtitle, "nice-dns has not checked this install yet.");

        let h = hero_of(&INSTALLED.replacen("controller\tstale\tno", "controller\tstale\tfuture", 1));
        assert_eq!(h.title, "Status is out of date");
        assert!(h.subtitle.contains("future"), "{}", h.subtitle);
    }

    #[test]
    fn hero_down_variants() {
        let h = hero_of(&obs_is(INSTALLED, "dns-owner", "unhealthy", "/etc/resolv.conf: nameserver 9.9.9.9"));
        assert_eq!(h.title, "This computer is not using nice-dns");
        assert_eq!(h.subtitle, "/etc/resolv.conf: nameserver 9.9.9.9");
        assert_eq!(h.tint, Tint::Down);

        let mut all = INSTALLED.to_string();
        for r in ["cloudflare-onion", "cloudflare-exit", "quad9-exit", "cloudflare-legacy"] {
            all = obs_is(&all, &format!("route:{r}"), "unhealthy", "no answer");
        }
        let h = hero_of(&all);
        assert_eq!((h.title.as_str(), h.subtitle.as_str()), ("DNS is down", "No route through Tor is answering."));

        let h = hero_of(&obs_is(INSTALLED, "container:unbound", "unhealthy", "exited"));
        assert_eq!((h.title.as_str(), h.subtitle.as_str()), ("DNS is down", "Unbound is not running"));

        // The first failing down check names it, and dns-owner wins over it.
        let both = obs_is(&obs_is(INSTALLED, "container:unbound", "unhealthy", "exited"), "dns-owner", "unhealthy", "r");
        assert_eq!(hero_of(&both).title, "This computer is not using nice-dns");

        let h = hero_of(&INSTALLED.replacen("controller\tverdict\tOK", "controller\tverdict\tFAIL [chain-resolves]", 1));
        assert_eq!(h.title, "DNS is down");
        assert_eq!(h.subtitle, "The lookup chain is not resolving.");
    }

    #[test]
    fn hero_never_prints_stale_seconds_or_the_word_healthy() {
        for text in [INSTALLED, STALE, UPDATE] {
            let h = hero_of(text);
            let all = format!("{} {}", h.title, h.subtitle);
            assert!(!all.contains("stale 942s") && !all.contains("healthy"), "{all}");
        }
    }

    // ------------------------------------------------------- the path

    fn path_of(text: &str) -> (Vec<Node>, String) {
        let s = st(text);
        path(&s, level(&s))
    }

    fn states(nodes: &[Node]) -> Vec<NodeState> {
        nodes.iter().map(|n| n.state).collect()
    }

    #[test]
    fn path_installed_has_five_nodes_all_ok_and_the_computer_neutral() {
        let (nodes, footer) = path_of(INSTALLED);
        assert_eq!(nodes.iter().map(|n| n.label.as_str()).collect::<Vec<_>>(), ["This computer", "Pi-hole", "Unbound", "Tor", "Cloudflare"]);
        assert_eq!(nodes.iter().map(|n| n.caption.as_str()).collect::<Vec<_>>(), ["Asks", "Blocks ads", "Resolves", "7 bridges", "Onion resolver"]);
        assert_eq!(
            states(&nodes),
            [NodeState::Neutral, NodeState::Ok, NodeState::Ok, NodeState::Ok, NodeState::Ok]
        );
        assert!(nodes.iter().all(|n| !n.dashed_in));
        assert_eq!(footer, "Answered in 1.9 s on the Cloudflare onion route. 3 backup routes are ready.");
        for n in &nodes {
            assert!(!n.caption.contains("healthy") && !n.label.contains("healthy"));
        }
    }

    #[test]
    fn path_backup_route_is_attention_with_a_dashed_line() {
        let (nodes, footer) = path_of(&onion_down_exit_selected());
        let r = &nodes[4];
        assert_eq!((r.label.as_str(), r.caption.as_str()), ("Cloudflare", "Backup: Tor exit"));
        assert_eq!(r.state, NodeState::Attention);
        assert!(r.dashed_in);
        assert!(nodes[..4].iter().all(|n| !n.dashed_in));
        assert_eq!(states(&nodes)[..4], [NodeState::Neutral, NodeState::Ok, NodeState::Ok, NodeState::Ok]);
        assert_eq!(footer, "Answered in 1.0 s on the Cloudflare Tor exit route. 2 backup routes are ready.");
    }

    #[test]
    fn path_node_state_is_the_worst_of_its_checks() {
        let (nodes, _) = path_of(&obs_is(INSTALLED, "filtering", "unhealthy", "x"));
        assert_eq!(nodes[1].state, NodeState::Attention);
        assert_eq!(nodes[1].caption, "Needs attention");
        let (nodes, _) = path_of(&obs_is(&obs_is(INSTALLED, "filtering", "unhealthy", "x"), "local-service", "unhealthy", "y"));
        assert_eq!(nodes[1].state, NodeState::Down);
        let (nodes, _) = path_of(&obs_is(INSTALLED, "container:tor-socat", "unhealthy", "exited"));
        assert_eq!(nodes[3].state, NodeState::Down);
        let (nodes, _) = path_of(&obs_is(INSTALLED, "unbound", "unhealthy", "x"));
        assert_eq!(nodes[2].state, NodeState::Down);
        let (nodes, _) = path_of(&obs_is(INSTALLED, "dns-owner", "unhealthy", "x"));
        assert_eq!(nodes[0].state, NodeState::Down);
        assert_eq!(nodes[0].caption, "Not using nice-dns");
        // A healthy route that is not in use does not colour the resolver.
        let (nodes, _) = path_of(&obs_is(INSTALLED, "route:quad9-exit", "unhealthy", "x"));
        assert_eq!(nodes[4].state, NodeState::Ok);
    }

    #[test]
    fn path_is_neutral_when_the_results_are_old() {
        for text in [STALE.to_string(), INSTALLED.replacen("controller\tstale\tno", "controller\tstale\tnever", 1)] {
            let (nodes, _) = path_of(&text);
            assert!(nodes.iter().all(|n| n.state == NodeState::Neutral), "{:?}", states(&nodes));
            assert!(nodes.iter().all(|n| !n.dashed_in));
        }
        let (nodes, _) = path_of(&onion_down_exit_selected().replacen("controller\tstale\tno", "controller\tstale\t300", 1));
        assert_eq!(nodes[4].caption, "Via Tor exit");
    }

    #[test]
    fn path_captions_follow_the_route_and_the_bridges_mode() {
        let sel = |id: &str| INSTALLED.replacen("route\tselected\tcloudflare-onion", &format!("route\tselected\t{id}"), 1);
        for (id, label, caption) in [
            ("cloudflare-exit", "Cloudflare", "Via Tor exit"),
            ("quad9-exit", "Quad9", "Via Tor exit"),
            ("cloudflare-legacy", "Cloudflare", "Onion, legacy port"),
        ] {
            let (nodes, _) = path_of(&sel(id));
            assert_eq!((nodes[4].label.as_str(), nodes[4].caption.as_str()), (label, caption), "{id}");
        }
        let (nodes, _) = path_of(&INSTALLED.replacen("bridges\tmode\ton", "bridges\tmode\toff", 1));
        assert_eq!(nodes[3].caption, "No bridges");
        let (nodes, _) = path_of(&INSTALLED.replacen("bridges\tcount\t7", "bridges\tcount\t1", 1));
        assert_eq!(nodes[3].caption, "1 bridge");
        // No route selected: the footer says so.
        let none: String = INSTALLED.lines().filter(|l| !l.starts_with("route\t")).map(|l| format!("{l}\n")).collect();
        let (nodes, footer) = path_of(&none);
        assert_eq!(footer, "No route selected yet.");
        assert_eq!(nodes[4].label, "Resolver");
    }

    #[test]
    fn path_all_routes_down_makes_the_resolver_down() {
        let mut all = INSTALLED.to_string();
        for r in ["cloudflare-onion", "cloudflare-exit", "quad9-exit", "cloudflare-legacy"] {
            all = obs_is(&all, &format!("route:{r}"), "unhealthy", "no answer");
        }
        let (nodes, footer) = path_of(&all);
        assert_eq!(nodes[4].state, NodeState::Down);
        assert!(footer.starts_with("The Cloudflare onion route is selected but not answering. 0 backup routes are ready."), "{footer}");
    }

    #[test]
    fn path_sentence_reads_the_whole_path() {
        let (nodes, _) = path_of(INSTALLED);
        let s = path_sentence(&nodes);
        assert!(s.starts_with("How a lookup travels: This computer (Asks, not checked), then Pi-hole (Blocks ads, working)"), "{s}");
    }

    // ------------------------------------------------------- attention

    #[test]
    fn attention_lists_the_failing_check_with_its_reason_worst_first() {
        let text = obs_is(&onion_down_exit_selected(), "filtering", "unhealthy", "doubleclick.net answered 1.2.3.4");
        let text = obs_is(&text, "container:pi-hole", "unhealthy", "exited 1");
        let rows = attention(&st(&text));
        assert_eq!(rows.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["container:pi-hole", "filtering", "route:cloudflare-onion"]);
        assert_eq!(rows[0].severity, Severity::Down);
        assert_eq!(rows[0].headline, "Pi-hole is not running");
        assert_eq!(rows[2].headline, "The Cloudflare onion route is not answering");
        assert_eq!(rows[2].reason, "no answer via tor-socat:18531 as tor.cloudflare-dns.com");
        assert!(attention(&st(INSTALLED)).is_empty());
        assert_eq!(attention_title(1), "1 check needs attention");
        assert_eq!(attention_title(3), "3 checks need attention");
    }

    #[test]
    fn attention_counts_an_indeterminate_check() {
        let rows = attention(&st(&obs_is(INSTALLED, "proxy", "indeterminate", "unreadable")));
        assert_eq!(rows.len(), 1);
        assert!(!rows[0].failing);
        assert_eq!(rows[0].severity, Severity::Attention);
    }

    // ------------------------------------------------------- groups

    #[test]
    fn groups_installed_are_three_collapsed_and_all_passing() {
        let g = groups(&st(INSTALLED));
        assert_eq!(g.iter().map(|g| g.title).collect::<Vec<_>>(), ["This computer", "Services", "Routes through Tor"]);
        assert_eq!(g.iter().map(|g| g.summary.as_str()).collect::<Vec<_>>(), ["5 passing", "6 passing", "4 passing"]);
        assert!(g.iter().all(|g| !g.expanded && g.worst == Severity::Healthy));
        assert_eq!(g[1].subtitle, "Pi-hole, Unbound, Tor proxy (socat), container runtime");
        assert_eq!(g.iter().map(|g| g.rows.len()).sum::<usize>(), 15);
        let onion = &g[2].rows[0];
        assert_eq!((onion.name.as_str(), onion.value.as_str(), onion.in_use), ("Cloudflare onion", "1.9 s", true));
        assert!(g[2].rows[1..].iter().all(|r| !r.in_use));
        assert_eq!(onion.record, "route:cloudflare-onion · healthy · 1930 ms\nrcode NOERROR in 0 ms via tor-socat:18531 as tor.cloudflare-dns.com");
        let runtime = g[1].rows.iter().find(|r| r.id == "runtime").unwrap();
        assert_eq!(runtime.value, "3 running");
        let owner = g[0].rows.iter().find(|r| r.id == "dns-owner").unwrap();
        assert!(owner.value.starts_with("/etc/resolv.conf"));
    }

    #[test]
    fn groups_a_failing_check_opens_its_group_and_sorts_first() {
        let g = groups(&st(&onion_down_exit_selected()));
        let routes = g.iter().find(|g| g.kind == GroupKind::Routes).unwrap();
        assert!(routes.expanded);
        assert_eq!(routes.summary, "1 failing");
        assert_eq!(routes.worst, Severity::Attention);
        assert_eq!(routes.rows[0].id, "route:cloudflare-onion");
        assert_eq!(g.iter().filter(|g| g.expanded).count(), 1);
        let g = groups(&st(&obs_is(INSTALLED, "proxy", "indeterminate", "x")));
        assert_eq!(g[1].summary, "1 unclear");
        let g = groups(&st(&obs_is(INSTALLED, "container:pi-hole", "unhealthy", "x")));
        assert_eq!(g[1].worst, Severity::Down);
    }

    #[test]
    fn groups_title_and_subtitle_of_the_checks_header() {
        assert_eq!(checks_title(&st(INSTALLED)), "15 of 15 checks passing");
        assert_eq!(checks_title(&st(&onion_down_exit_selected())), "1 of 15 checks need attention");
        assert_eq!(checks_subtitle(&st(INSTALLED), NOW), "Last pass 1 min ago.");
        assert_eq!(checks_subtitle(&st(&INSTALLED.replacen("controller\tlast_pass\t1794251828", "controller\tlast_pass\tnever", 1)), NOW), "No pass yet.");
        let none: String = INSTALLED.lines().filter(|l| !l.starts_with("obs\t")).map(|l| format!("{l}\n")).collect();
        assert_eq!(checks_title(&st(&none)), "No checks recorded yet");
    }

    // ------------------------------------------------------- update row

    #[test]
    fn update_row_current_names_the_branch_and_when() {
        let scheduled = INSTALLED.replacen(
            "update\tresult\tunknown\tnever-checked\n",
            &format!("update\tresult\tcurrent\nupdate\tchecked_at\t{}\n", NOW - 7200),
            1,
        );
        let r = update_row(&st(&scheduled), NOW);
        assert_eq!((r.title, r.button, r.suggested), ("Up to date", "update-check", false));
        assert_eq!(r.subtitle, "Branch main, checked 2 h ago. nice-dns checks twice a day.");
        assert_eq!(r.button_label, "Check for update");
        let stopped = scheduled.replacen("update\tauto\tloaded", "update\tauto\tstopped", 1);
        assert_eq!(update_row(&st(&stopped), NOW).subtitle, "Branch main, checked 2 h ago.");
    }

    #[test]
    fn update_row_available_offers_install_with_the_commit() {
        let r = update_row(&st(UPDATE), NOW);
        assert_eq!((r.title, r.button, r.suggested), ("Update available", "update", true));
        assert_eq!(r.button_label, "Install\u{2026}");
        assert_eq!(r.subtitle, "Branch main is now at 0f6a6e7c3d2b, found just now.");
    }

    #[test]
    fn update_row_unknown_variants() {
        let r = update_row(&st(INSTALLED), NOW);
        assert_eq!((r.title, r.button, r.subtitle.as_str()), ("Not checked yet", "update-check", ""));
        let tried = INSTALLED.replacen("update\tresult\tunknown\tnever-checked\n", &format!("update\tresult\tunknown\nupdate\tchecked_at\t{}\n", NOW - 600), 1);
        let r = update_row(&st(&tried), NOW);
        assert_eq!((r.title, r.subtitle.as_str()), ("Could not check for updates", "Last tried 10 min ago."));
    }

    // ------------------------------------------------------- repairs

    #[test]
    fn repairs_collapse_each_target_to_one_line_newest_first() {
        let r = repairs(&st(INSTALLED), NOW);
        assert_eq!(
            r.iter().map(|r| r.text.as_str()).collect::<Vec<_>>(),
            ["Moved back to the Cloudflare onion route", "Moved to the Cloudflare Tor exit route"]
        );
        assert_eq!(r[0].when, "1 h ago");
        assert_eq!(last_repair_link(&r).unwrap(), "Last repair 1 h ago \u{b7} Moved back to the Cloudflare onion route");
        assert_eq!(last_repair_link(&[]), None);
    }

    #[test]
    fn repairs_say_what_is_in_progress_and_name_other_targets() {
        let text = INSTALLED.replacen(
            "recent\t1794247806\troute:cloudflare-onion\tready\n",
            "recent\t1794247806\troute:cloudflare-onion\tacknowledged\nrecent\t1794247900\tbridges\trequested\nrecent\t1794247950\tunbound\tready\nrecent\t1794247960\tsomething-else\tready\nrecent\t1794247970\ttor\tready\n",
            1,
        );
        let r = repairs(&st(&text), NOW);
        let t: Vec<&str> = r.iter().map(|r| r.text.as_str()).collect();
        assert_eq!(
            t,
            [
                "Restarted Tor proxy",
                "something-else",
                "Restarted Unbound",
                "Bridges turned on (in progress)",
                "Moved back to the Cloudflare onion route (in progress)",
            ]
        );
        assert_eq!(r.len(), 5);
        let none = INSTALLED.replacen("recent\t1794247806\troute:cloudflare-onion\tready\n", "recent\t1794247806\troute:cloudflare-onion\tnot-acknowledged\n", 1);
        assert_eq!(repairs(&st(&none), NOW)[0].text, "Moved back to the Cloudflare onion route (not-acknowledged)");
    }

    #[test]
    fn repairs_are_empty_without_a_journal() {
        let none: String = INSTALLED.lines().filter(|l| !l.starts_with("recent\t")).map(|l| format!("{l}\n")).collect();
        assert!(repairs(&st(&none), NOW).is_empty());
    }

    // ------------------------------------------------------- small rows

    #[test]
    fn small_rows() {
        assert_eq!(admin_subtitle(Some("http://localhost:8880/admin")), "Blocklists and query log at localhost:8880/admin");
        assert_eq!(admin_subtitle(None), "Blocklists and query log");
        assert!(bridges_subtitle(true).starts_with("Hides Tor use from your internet provider."));
        assert!(bridges_subtitle(false).starts_with("Off. Your provider can see that Tor is in use."));
        assert_eq!(bridges_tooltip(&st(INSTALLED), NOW).unwrap(), "Bridges have not been refreshed yet");
        let refreshed = INSTALLED.replacen("bridges\tlast_refresh\tnever", &format!("bridges\tlast_refresh\t{}", NOW - 3 * 3600), 1);
        assert_eq!(bridges_tooltip(&st(&refreshed), NOW).unwrap(), "Bridges last refreshed 3 h ago");
        assert_eq!(installed_on("20261109T180318Z-nogit0000000").unwrap(), "9 November 2026");
        assert_eq!(installed_on("garbage"), None);
        assert_eq!(installed_on("20261309T1"), None);
        assert_eq!(ago(NOW - 5, NOW), "just now");
        assert_eq!(ago(NOW - 300, NOW), "5 min ago");
        assert_eq!(ago(NOW - 7200, NOW), "2 h ago");
        assert_eq!(ago(NOW - 3 * 86_400, NOW), "3 days ago");
        assert_eq!(ago(NOW + 10, NOW), "in the future");
        assert_eq!(short("0f6a6e7c3d2b1a09"), "0f6a6e7c3d2b");
        assert_eq!(short("abc"), "abc");
    }
}
