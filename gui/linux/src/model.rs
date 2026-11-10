//! The `nice-dns status --tsv` contract (`docs/cli-contract.md`), schema
//! `nice-dns-status/1`, parsed into typed records. GTK-free.

use std::fmt;

pub const SCHEMA: &str = "nice-dns-status/1";

/// Why a status text was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    /// The first line is not a schema row; `found` is that line (empty when
    /// there was no output at all).
    NoSchema { found: String },
    /// A schema row naming another schema.
    WrongSchema { found: String },
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::NoSchema { found } if found.is_empty() => {
                write!(f, "no schema line: the status output is empty")
            }
            ParseError::NoSchema { found } => {
                write!(f, "no schema line: the first line is '{found}'")
            }
            ParseError::WrongSchema { found } => {
                write!(f, "schema '{found}' is not {SCHEMA}")
            }
        }
    }
}

impl std::error::Error for ParseError {}

/// `controller stale`: `no`, a number of seconds, `never` or `future`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stale {
    No,
    Seconds(u64),
    Never,
    Future,
}

impl Stale {
    fn parse(v: &str) -> Option<Stale> {
        match v {
            "no" => Some(Stale::No),
            "never" => Some(Stale::Never),
            "future" => Some(Stale::Future),
            n => n.parse().ok().map(Stale::Seconds),
        }
    }
}

impl fmt::Display for Stale {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Stale::No => write!(f, "fresh"),
            Stale::Seconds(s) => write!(f, "stale {s}s"),
            Stale::Never => write!(f, "no pass yet"),
            Stale::Future => write!(f, "pass dated in the future"),
        }
    }
}

/// An `<epoch>|never` value (`controller last_pass`, `bridges last_refresh`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Moment {
    At(u64),
    Never,
}

impl Moment {
    fn parse(v: &str) -> Option<Moment> {
        match v {
            "never" => Some(Moment::Never),
            n => n.parse().ok().map(Moment::At),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateResult {
    Current,
    Available,
    Unknown,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Install {
    pub installed: Option<bool>,
    pub generation: Option<String>,
    pub source_commit: Option<String>,
    pub branch: Option<String>,
    pub variant: Option<String>,
    pub pihole: Option<String>,
    pub platform: Option<String>,
    pub lock: Option<String>,
    pub hint: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Controller {
    pub mode: Option<String>,
    pub last_pass: Option<Moment>,
    pub verdict: Option<String>,
    pub stale: Option<Stale>,
    pub schedule: Option<String>,
}

/// One `obs<TAB>name<TAB>verdict<TAB>ms<TAB>reason` record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Obs {
    pub name: String,
    pub verdict: String,
    pub ms: Option<u64>,
    pub reason: String,
}

/// `route selected <route id> <state generation>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Route {
    pub id: String,
    pub generation: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Bridges {
    pub mode: Option<String>,
    pub count: Option<u32>,
    pub last_refresh: Option<Moment>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Update {
    pub result: Option<UpdateResult>,
    pub never_checked: bool,
    pub checked_at: Option<u64>,
    pub remote_commit: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Helper {
    pub path: Option<String>,
    pub installed: Option<bool>,
    pub version: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Admin {
    pub url: Option<String>,
    pub password_path: Option<String>,
}

/// One `recent<TAB><epoch><TAB><target><TAB><result>` journal row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Recent {
    pub epoch: Option<u64>,
    pub target: String,
    pub result: String,
}

/// A `<group> unreadable <reason>` row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unreadable {
    pub group: String,
    pub reason: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Status {
    pub install: Install,
    pub controller: Controller,
    pub obs: Vec<Obs>,
    pub route: Option<Route>,
    pub bridges: Bridges,
    pub update: Update,
    pub helper: Helper,
    pub admin: Admin,
    pub recent: Vec<Recent>,
    pub unreadable: Vec<Unreadable>,
}

impl Status {
    /// The `unreadable` reasons of one group, in order. The window lists every
    /// unreadable row at once; the contract tests read them per group.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn unreadable_in<'a>(&'a self, group: &'a str) -> impl Iterator<Item = &'a str> + 'a {
        self.unreadable
            .iter()
            .filter(move |u| u.group == group)
            .map(|u| u.reason.as_str())
    }
}

fn yes_no(v: &str) -> Option<bool> {
    match v {
        "yes" => Some(true),
        "no" => Some(false),
        _ => None,
    }
}

fn text(v: &str) -> Option<String> {
    Some(v.to_string())
}

/// Parse `status --tsv` output. The first line must be the schema row; rows
/// of a group or key this reader does not know are ignored, as the contract
/// says, and so is a known row too short to carry its values.
pub fn parse(input: &str) -> Result<Status, ParseError> {
    let mut lines = input.lines();
    let first = lines.next().unwrap_or("");
    check_schema(first)?;

    let mut s = Status::default();
    for line in lines {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 3 {
            continue;
        }
        let (group, key, val) = (f[0], f[1], f[2]);
        if key == "unreadable" && f.len() == 3 {
            s.unreadable.push(Unreadable { group: group.to_string(), reason: val.to_string() });
            continue;
        }
        match group {
            "install" => {
                let i = &mut s.install;
                match key {
                    "installed" => i.installed = yes_no(val),
                    "generation" => i.generation = text(val),
                    "source_commit" => i.source_commit = text(val),
                    "branch" => i.branch = text(val),
                    "variant" => i.variant = text(val),
                    "pihole" => i.pihole = text(val),
                    "platform" => i.platform = text(val),
                    "lock" => i.lock = text(val),
                    "hint" => i.hint = text(val),
                    _ => {}
                }
            }
            "controller" => {
                let c = &mut s.controller;
                match key {
                    "mode" => c.mode = text(val),
                    "last_pass" => c.last_pass = Moment::parse(val),
                    "verdict" => c.verdict = text(val),
                    "stale" => c.stale = Stale::parse(val),
                    "schedule" => c.schedule = text(val),
                    _ => {}
                }
            }
            "obs" if f.len() >= 5 => s.obs.push(Obs {
                name: key.to_string(),
                verdict: val.to_string(),
                ms: f[3].parse().ok(),
                reason: f[4].to_string(),
            }),
            "route" if key == "selected" && f.len() >= 4 => {
                s.route = Some(Route { id: val.to_string(), generation: f[3].to_string() })
            }
            "bridges" => {
                let b = &mut s.bridges;
                match key {
                    "mode" => b.mode = text(val),
                    "count" => b.count = val.parse().ok(),
                    "last_refresh" => b.last_refresh = Moment::parse(val),
                    _ => {}
                }
            }
            "update" => {
                let u = &mut s.update;
                match key {
                    "result" => {
                        u.result = match val {
                            "current" => Some(UpdateResult::Current),
                            "available" => Some(UpdateResult::Available),
                            "unknown" => Some(UpdateResult::Unknown),
                            _ => None,
                        };
                        u.never_checked = f.get(3) == Some(&"never-checked");
                    }
                    "checked_at" => u.checked_at = val.parse().ok(),
                    "remote_commit" => u.remote_commit = text(val),
                    _ => {}
                }
            }
            "helper" => {
                let h = &mut s.helper;
                match key {
                    "path" => h.path = text(val),
                    "installed" => h.installed = yes_no(val),
                    "version" => h.version = text(val),
                    _ => {}
                }
            }
            "admin" => {
                let a = &mut s.admin;
                match key {
                    "url" => a.url = text(val),
                    "password_path" => a.password_path = text(val),
                    _ => {}
                }
            }
            "recent" if f.len() >= 4 => s.recent.push(Recent {
                epoch: key.parse().ok(),
                target: val.to_string(),
                result: f[3].to_string(),
            }),
            _ => {}
        }
    }
    Ok(s)
}

fn check_schema(first: &str) -> Result<(), ParseError> {
    match first.split_once('\t') {
        Some(("schema", SCHEMA)) => Ok(()),
        Some(("schema", other)) => Err(ParseError::WrongSchema { found: other.to_string() }),
        _ => Err(ParseError::NoSchema { found: first.to_string() }),
    }
}

/// What the window shows for one run of the status command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum View {
    /// Exit 0 with an installed stack.
    Installed(Status),
    /// Nothing is installed: exit 1, or exit 2 with `install installed no`
    /// (the contract's 2 wins over 1) and its `unreadable` rows. `hint` is
    /// the `install hint` row, when given.
    NotInstalled { hint: Option<String>, unreadable: Vec<Unreadable> },
    /// Exit 2 with rows of an installed stack: some file `status` reads
    /// cannot be read.
    Unreadable(Status),
    /// Anything else: exit 2 with nothing on stdout, another code, a signal,
    /// a refused schema, or rows that contradict the exit code.
    Error(String),
}

/// Map the status command's exit code (`None`: killed by a signal) and its
/// stdout to what the window shows.
pub fn classify(code: Option<i32>, stdout: &str) -> View {
    let parsed = || parse(stdout);
    match code {
        Some(0) => match parsed() {
            Ok(s) if s.install.installed == Some(true) => View::Installed(s),
            Ok(_) => View::Error("status exited 0 but does not say 'install installed yes'".into()),
            Err(e) => View::Error(e.to_string()),
        },
        Some(1) => match parsed() {
            Ok(s) if s.install.installed == Some(false) => {
                View::NotInstalled { hint: s.install.hint, unreadable: Vec::new() }
            }
            Ok(_) => View::Error("status exited 1 but does not say 'install installed no'".into()),
            Err(e) => View::Error(e.to_string()),
        },
        Some(2) if stdout.trim().is_empty() => {
            View::Error("status exited 2 with nothing on stdout".into())
        }
        Some(2) => match parsed() {
            Ok(s) if s.install.installed == Some(false) => {
                View::NotInstalled { hint: s.install.hint, unreadable: s.unreadable }
            }
            Ok(s) => View::Unreadable(s),
            Err(e) => View::Error(e.to_string()),
        },
        Some(n) => View::Error(format!("status exited {n}")),
        None => View::Error("status was killed by a signal".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const INSTALLED: &str = include_str!("../../share/fixtures/status-installed.tsv");
    const NOT_INSTALLED: &str = include_str!("../../share/fixtures/status-not-installed.tsv");
    const STALE: &str = include_str!("../../share/fixtures/status-stale.tsv");
    const UPDATE: &str = include_str!("../../share/fixtures/status-update-available.tsv");

    #[test]
    fn contract_wrong_schema_is_refused() {
        let text = INSTALLED.replacen(SCHEMA, "nice-dns-status/2", 1);
        assert_eq!(
            parse(&text),
            Err(ParseError::WrongSchema { found: "nice-dns-status/2".into() })
        );
        assert!(matches!(classify(Some(0), &text), View::Error(m) if m.contains("nice-dns-status/2")));
    }

    #[test]
    fn contract_missing_schema_line_is_refused() {
        let text: String = INSTALLED.lines().skip(1).map(|l| format!("{l}\n")).collect();
        assert_eq!(
            parse(&text),
            Err(ParseError::NoSchema { found: "install\tinstalled\tyes".into() })
        );
        assert_eq!(parse(""), Err(ParseError::NoSchema { found: String::new() }));
    }

    #[test]
    fn contract_installed_fixture_parses() {
        let s = parse(INSTALLED).unwrap();
        assert_eq!(s.install.installed, Some(true));
        assert_eq!(s.install.generation.as_deref(), Some("20261109T180318Z-nogit0000000"));
        assert_eq!(s.install.variant.as_deref(), Some("socat"));
        assert_eq!(s.install.platform.as_deref(), Some("linux"));
        assert_eq!(s.controller.verdict.as_deref(), Some("OK"));
        assert_eq!(s.controller.stale, Some(Stale::No));
        assert_eq!(s.controller.last_pass, Some(Moment::At(1794251828)));
        assert_eq!(s.obs.len(), 15);
        assert_eq!(
            s.obs[10],
            Obs {
                name: "route:cloudflare-onion".into(),
                verdict: "healthy".into(),
                ms: Some(1930),
                reason: "rcode NOERROR in 0 ms via tor-socat:18531 as tor.cloudflare-dns.com".into(),
            }
        );
        assert_eq!(s.route, Some(Route { id: "cloudflare-onion".into(), generation: "73".into() }));
        assert_eq!(s.bridges.mode.as_deref(), Some("on"));
        assert_eq!(s.bridges.count, Some(7));
        assert_eq!(s.bridges.last_refresh, Some(Moment::Never));
        assert_eq!(s.update.result, Some(UpdateResult::Unknown));
        assert!(s.update.never_checked);
        assert_eq!(s.helper.version.as_deref(), Some("0.1.1"));
        assert_eq!(s.helper.installed, Some(true));
        assert_eq!(s.admin.url.as_deref(), Some("http://localhost:8880/admin"));
        assert_eq!(s.recent.len(), 5);
        assert_eq!(s.recent[4].epoch, Some(1794247806));
        assert_eq!(s.recent[4].result, "ready");
        assert!(s.unreadable.is_empty());
        assert!(matches!(classify(Some(0), INSTALLED), View::Installed(_)));
    }

    #[test]
    fn contract_not_installed_fixture_parses() {
        let s = parse(NOT_INSTALLED).unwrap();
        assert_eq!(s.install.installed, Some(false));
        assert_eq!(s.install.generation, None);
        assert!(s.obs.is_empty());
        let hint = s.install.hint.clone().unwrap();
        assert!(hint.starts_with("curl -fsSL https://raw.githubusercontent.com/sureserverman/nice-dns/main/install-deb.sh"));
        assert_eq!(classify(Some(1), NOT_INSTALLED), View::NotInstalled { hint: Some(hint.clone()), unreadable: vec![] });
        // Exit 2 with `installed no`: still not installed, with the unreadable rows.
        let both = format!("{NOT_INSTALLED}bridges\tunreadable\t~/x: permission denied\n");
        assert_eq!(
            classify(Some(2), &both),
            View::NotInstalled {
                hint: Some(hint),
                unreadable: vec![Unreadable { group: "bridges".into(), reason: "~/x: permission denied".into() }]
            }
        );
    }

    #[test]
    fn contract_stale_fixture_parses() {
        let s = parse(STALE).unwrap();
        assert_eq!(s.install.generation.as_deref(), Some("20261109T180318Z-nogit0000000"));
        assert_eq!(s.controller.stale, Some(Stale::Seconds(942)));
        assert_eq!(s.controller.verdict.as_deref(), Some("OK"));
        assert_eq!(s.obs.len(), 15);
        assert!(matches!(classify(Some(0), STALE), View::Installed(_)));
    }

    #[test]
    fn contract_update_available_fixture_parses() {
        let s = parse(UPDATE).unwrap();
        assert_eq!(s.install.variant.as_deref(), Some("socat"));
        assert_eq!(s.update.result, Some(UpdateResult::Available));
        assert!(!s.update.never_checked);
        assert_eq!(s.update.checked_at, Some(1794251900));
        assert_eq!(s.update.remote_commit.as_deref(), Some("0f6a6e7c3d2b1a09f8e7d6c5b4a39281706f5e4d"));
        assert_eq!(s.helper.version.as_deref(), Some("0.1.1"));
    }

    #[test]
    fn contract_stale_values_parse_to_the_enum() {
        assert_eq!(Stale::parse("no"), Some(Stale::No));
        assert_eq!(Stale::parse("942"), Some(Stale::Seconds(942)));
        assert_eq!(Stale::parse("never"), Some(Stale::Never));
        assert_eq!(Stale::parse("future"), Some(Stale::Future));
        assert_eq!(Stale::parse("soon"), None);
    }

    #[test]
    fn contract_unknown_group_and_key_are_ignored() {
        let text = format!("{INSTALLED}newgroup\tthing\tvalue\ninstall\tnewkey\tvalue\nbridges\tcolour\tblue\n");
        assert_eq!(parse(&text).unwrap(), parse(INSTALLED).unwrap());
    }

    #[test]
    fn contract_unreadable_row_is_kept() {
        let text = INSTALLED.replacen(
            "bridges\tcount\t7\n",
            "bridges\tunreadable\t~/.config/nice-dns/bridges.env: permission denied\n",
            1,
        );
        let s = parse(&text).unwrap();
        assert_eq!(s.bridges.count, None);
        assert_eq!(
            s.unreadable_in("bridges").collect::<Vec<_>>(),
            ["~/.config/nice-dns/bridges.env: permission denied"]
        );
        assert_eq!(s.unreadable_in("install").count(), 0);
        assert!(matches!(classify(Some(2), &text), View::Unreadable(u) if u == s));
    }

    #[test]
    fn contract_exit_codes_map_to_views() {
        assert!(matches!(classify(Some(2), ""), View::Error(_)));
        assert!(matches!(classify(Some(3), INSTALLED), View::Error(m) if m == "status exited 3"));
        assert!(matches!(classify(None, INSTALLED), View::Error(_)));
        assert!(matches!(classify(Some(1), INSTALLED), View::Error(_)));
        assert!(matches!(classify(Some(0), NOT_INSTALLED), View::Error(_)));
    }
}
