//! The shared action table, `gui/share/actions.tsv`, compiled in.
//!
//! One header-less row per action:
//! `id<TAB>label<TAB>command words<TAB>needs-confirm<TAB>needs-installed`.
//! The command words are the program (`nice-dns` or `nice-dns-health`) and its
//! arguments, space-separated; `-` marks an action that runs no subprocess.

use std::sync::OnceLock;

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

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(id: &str) -> Vec<&'static str> {
        let a = lookup(id).unwrap_or_else(|| panic!("no action {id}"));
        a.program.into_iter().chain(a.args.iter().copied()).collect()
    }

    #[test]
    fn actions_table_parses_with_five_fields_per_row() {
        assert!(TABLE.lines().all(|l| l.split('\t').count() == 5));
        assert_eq!(all().len(), TABLE.lines().count());
        assert_eq!(all().len(), 14);
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
        for verb in ["install", "reinstall", "restart", "uninstall", "update", "bridges"] {
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
    fn actions_confirm_and_installed_flags() {
        for id in ["reinstall", "uninstall", "update"] {
            assert!(lookup(id).unwrap().needs_confirm, "{id}");
        }
        assert!(!lookup("restart").unwrap().needs_confirm);
        assert!(!lookup("install").unwrap().needs_installed);
        assert!(all().iter().filter(|a| a.id != "install").all(|a| a.needs_installed));
        assert_eq!(lookup("bridges-off").unwrap().label, "Turn bridges off");
        assert_eq!(lookup("nope"), None);
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
