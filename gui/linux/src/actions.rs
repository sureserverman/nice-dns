//! The shared action table, `gui/share/actions.tsv`, compiled in.
//!
//! One header-less row per action:
//! `id<TAB>label<TAB>command words<TAB>needs-confirm<TAB>needs-installed`.
//! The command words are the program (`nice-dns` or `nice-dns-health`) and its
//! arguments, space-separated; `-` marks an action that runs no subprocess.

use std::path::PathBuf;
use std::sync::OnceLock;

use crate::runner::NotFound;

const TABLE: &str = include_str!("../../share/actions.tsv");

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Action<'a> {
    pub id: &'a str,
    pub label: &'a str,
    /// `None` for an action that is not a subprocess.
    pub program: Option<&'a str>,
    pub args: Vec<&'a str>,
    pub needs_confirm: bool,
    pub needs_installed: bool,
}

fn flag(v: &str, what: &str, n: usize) -> Result<bool, String> {
    match v {
        "yes" => Ok(true),
        "no" => Ok(false),
        _ => Err(format!("line {n}: {what} is '{v}', not yes or no")),
    }
}

/// Parse an action table; any malformed row refuses the whole table.
pub fn parse(text: &str) -> Result<Vec<Action<'_>>, String> {
    let mut out: Vec<Action<'_>> = Vec::new();
    for (i, line) in text.lines().enumerate() {
        let n = i + 1;
        if line.is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        let [id, label, words, confirm, installed] = f[..] else {
            return Err(format!("line {n}: {} fields, not 5", f.len()));
        };
        if id.is_empty() || label.is_empty() || words.is_empty() {
            return Err(format!("line {n}: an empty id, label or command"));
        }
        if out.iter().any(|a| a.id == id) {
            return Err(format!("line {n}: duplicate id '{id}'"));
        }
        let (program, args) = if words == "-" {
            (None, Vec::new())
        } else {
            let mut w = words.split(' ');
            let p = w.next().filter(|p| !p.is_empty());
            let args: Vec<&str> = w.collect();
            if p.is_none() || args.iter().any(|a| a.is_empty()) {
                return Err(format!("line {n}: malformed command '{words}'"));
            }
            (p, args)
        };
        out.push(Action {
            id,
            label,
            program,
            args,
            needs_confirm: flag(confirm, "needs-confirm", n)?,
            needs_installed: flag(installed, "needs-installed", n)?,
        });
    }
    Ok(out)
}

/// Every action of the compiled-in table, in table order.
pub fn all() -> &'static [Action<'static>] {
    static ACTIONS: OnceLock<Vec<Action<'static>>> = OnceLock::new();
    // The table is part of the binary; the actions_ tests refuse a bad one.
    ACTIONS.get_or_init(|| parse(TABLE).expect("gui/share/actions.tsv is well-formed"))
}

pub fn lookup(id: &str) -> Option<&'static Action<'static>> {
    all().iter().find(|a| a.id == id)
}

/// The reinstall dialog's choices, prefilled from `status`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Choices {
    pub variant: String,
    pub pihole: String,
    pub branch: String,
}

impl Choices {
    /// The words `nice-dns reinstall` takes for these choices, or why they
    /// cannot be passed (an unknown variant or flavour, an empty branch, or one
    /// that looks like an option).
    pub fn words(&self) -> Result<Vec<String>, String> {
        if !matches!(self.variant.as_str(), "haproxy" | "socat") {
            return Err(format!("unknown proxy '{}'", self.variant));
        }
        let flavour = match self.pihole.as_str() {
            "standard" => "--standard",
            "hardened" => "--hardened",
            other => return Err(format!("unknown Pi-hole flavour '{other}'")),
        };
        let b = self.branch.trim();
        if b.is_empty() || b.starts_with('-') || b.chars().any(|c| c.is_whitespace() || c.is_control()) {
            return Err(format!("'{}' is not a branch name", self.branch));
        }
        Ok(vec![self.variant.clone(), flavour.into(), "--branch".into(), b.into()])
    }
}

/// The argv that runs action `id`: its program found by `resolve`, then the
/// table's words, and for `reinstall` with `choices` those choices. `Ok(None)`
/// for an action that runs no command.
pub fn argv(
    id: &str,
    choices: Option<&Choices>,
    resolve: impl Fn(&str) -> Result<PathBuf, NotFound>,
) -> Result<Option<Vec<String>>, String> {
    let a = lookup(id).ok_or_else(|| format!("no action '{id}'"))?;
    let Some(program) = a.program else { return Ok(None) };
    let path = resolve(program).map_err(|nf| format!("{program} is not installed: looked for {}", nf.primary.display()))?;
    let mut v = vec![path.to_string_lossy().into_owned()];
    v.extend(a.args.iter().map(|w| w.to_string()));
    if let (Some(c), "reinstall") = (choices, id) {
        v.extend(c.words()?);
    }
    Ok(Some(v))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at_bin(name: &str) -> Result<PathBuf, NotFound> {
        Ok(PathBuf::from("/h/.local/bin").join(name))
    }

    fn argv(id: &str) -> Vec<&'static str> {
        let a = lookup(id).unwrap_or_else(|| panic!("no action {id}"));
        a.program.into_iter().chain(a.args.iter().copied()).collect()
    }

    #[test]
    fn actions_table_parses_with_five_fields_per_row() {
        assert!(TABLE.lines().all(|l| l.split('\t').count() == 5));
        assert_eq!(all().len(), TABLE.lines().count());
        assert_eq!(all().len(), 18);
    }

    #[test]
    fn actions_ids_are_unique() {
        let mut ids: Vec<&str> = all().iter().map(|a| a.id).collect();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), all().len());
    }

    #[test]
    fn actions_reach_every_cli_command_and_controller_verb() {
        let reached = |program: &str, verb: &str| {
            all().iter().any(|a| a.program == Some(program) && a.args.first() == Some(&verb))
        };
        for verb in ["install", "reinstall", "restart", "uninstall", "update", "bridges", "switch"] {
            assert!(reached("nice-dns", verb), "nice-dns {verb}");
        }
        for verb in ["start", "stop", "run"] {
            assert!(reached("nice-dns-health", verb), "nice-dns-health {verb}");
        }
        for a in all() {
            assert!(matches!(a.program, None | Some("nice-dns") | Some("nice-dns-health")), "{}", a.id);
        }
    }

    #[test]
    fn actions_exact_argv() {
        assert_eq!(argv("bridges-off"), ["nice-dns", "bridges", "off"]);
        assert_eq!(argv("health-run"), ["nice-dns-health", "run"]);
        assert_eq!(argv("update-check"), ["nice-dns", "update", "--check"]);
        assert_eq!(argv("open-admin"), Vec::<&str>::new());
        assert_eq!(argv("show-password-path"), Vec::<&str>::new());
    }

    #[test]
    fn actions_the_four_switches_change_one_choice_and_ask_first() {
        for (id, words) in [
            ("proxy-haproxy", ["nice-dns", "switch", "proxy", "haproxy"]),
            ("proxy-socat", ["nice-dns", "switch", "proxy", "socat"]),
            ("pihole-standard", ["nice-dns", "switch", "pihole", "standard"]),
            ("pihole-hardened", ["nice-dns", "switch", "pihole", "hardened"]),
        ] {
            assert_eq!(argv(id), words, "{id}");
            let a = lookup(id).unwrap();
            assert!(a.needs_confirm, "{id} asks first: it reinstalls the stack");
            assert!(a.needs_installed, "{id} needs an install");
        }
    }

    #[test]
    fn actions_confirm_and_installed_flags() {
        for id in ["reinstall", "uninstall", "update", "proxy-haproxy", "proxy-socat", "pihole-standard", "pihole-hardened"] {
            assert!(lookup(id).unwrap().needs_confirm, "{id}");
        }
        assert!(!lookup("restart").unwrap().needs_confirm);
        assert!(!lookup("install").unwrap().needs_installed);
        assert!(all().iter().filter(|a| a.id != "install").all(|a| a.needs_installed));
        assert_eq!(lookup("bridges-off").unwrap().label, "Turn bridges off");
        assert_eq!(lookup("nope"), None);
    }

    #[test]
    fn actions_argv_runs_the_resolved_program_with_the_table_words() {
        let run = |id| super::argv(id, None, at_bin).unwrap().unwrap();
        assert_eq!(run("bridges-off"), ["/h/.local/bin/nice-dns", "bridges", "off"]);
        assert_eq!(run("bridges-on"), ["/h/.local/bin/nice-dns", "bridges", "on"]);
        assert_eq!(run("restart"), ["/h/.local/bin/nice-dns", "restart"]);
        assert_eq!(run("health-start"), ["/h/.local/bin/nice-dns-health", "start"]);
        assert_eq!(super::argv("open-admin", None, at_bin).unwrap(), None);
        let missing = super::argv("restart", None, |n| Err(NotFound { primary: PathBuf::from("/h/.local/bin").join(n) }));
        assert_eq!(missing.unwrap_err(), "nice-dns is not installed: looked for /h/.local/bin/nice-dns");
        assert!(super::argv("nope", None, at_bin).is_err());
    }

    #[test]
    fn actions_reinstall_passes_the_chosen_variant_flavour_and_branch() {
        let c = Choices { variant: "socat".into(), pihole: "hardened".into(), branch: "main".into() };
        assert_eq!(
            super::argv("reinstall", Some(&c), at_bin).unwrap().unwrap(),
            ["/h/.local/bin/nice-dns", "reinstall", "socat", "--hardened", "--branch", "main"]
        );
        let std = Choices { pihole: "standard".into(), ..c.clone() };
        assert_eq!(std.words().unwrap()[1], "--standard");
        for bad in [
            Choices { variant: "tor".into(), ..c.clone() },
            Choices { pihole: "extra".into(), ..c.clone() },
            Choices { branch: "--local".into(), ..c.clone() },
            Choices { branch: "a b".into(), ..c.clone() },
            Choices { branch: " ".into(), ..c.clone() },
        ] {
            assert!(super::argv("reinstall", Some(&bad), at_bin).is_err(), "{bad:?}");
        }
        // Without choices reinstall uses the recorded ones.
        assert_eq!(super::argv("reinstall", None, at_bin).unwrap().unwrap(), ["/h/.local/bin/nice-dns", "reinstall"]);
    }

    #[test]
    fn actions_malformed_rows_are_refused() {
        assert!(parse("a\tA\tnice-dns x\tyes\n").unwrap_err().contains("4 fields"));
        assert!(parse("a\tA\tnice-dns x\tyes\tno\textra\n").unwrap_err().contains("6 fields"));
        assert!(parse("a\tA\tnice-dns x\tmaybe\tno\n").unwrap_err().contains("needs-confirm"));
        assert!(parse("a\tA\tnice-dns x\tno\tyes\na\tB\tnice-dns y\tno\tyes\n")
            .unwrap_err()
            .contains("duplicate"));
        assert!(parse("a\tA\tnice-dns  x\tno\tyes\n").unwrap_err().contains("malformed"));
        assert!(parse("a\t\tnice-dns x\tno\tyes\n").unwrap_err().contains("empty"));
        assert_eq!(parse("a\tA\t-\tno\tno\n").unwrap()[0].program, None);
    }
}
