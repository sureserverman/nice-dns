//! nice-dns-helper: validates, scrubs, then execs the root-held root-ops.
//! THREAT-MODEL.md says what each step is for.

mod caller;
mod exec;
mod verbs;

#[cfg(test)]
mod tests;

use std::ffi::{OsStr, OsString};
use std::io::Write;

use exec::{check_root_held, ModeRule, RealSys, Sys};
use verbs::{is, Platform, Want};

/// How a run ends: the exit status and, when it is a refusal, the message.
#[derive(Debug)]
pub struct Exit {
    pub code: i32,
    pub msg: String,
}

fn refuse(code: i32, msg: impl Into<String>) -> Exit {
    Exit { code, msg: msg.into() }
}

const USAGE: &str = "\
usage: nice-dns-helper --tree <dir> <verb> [argument...]
       nice-dns-helper --list-verbs --platform deb|mac
       nice-dns-helper --version
Runs one verb of nice-dns' root-ops as root, for the user who called it.
";

fn display(tok: &OsStr) -> String {
    tok.to_string_lossy().into_owned()
}

/// The whole decision flow. Order: static grammar (2), caller (1), path
/// arguments (2), root-ops trust (3), then privilege setup and exec (3).
pub fn run(
    sys: &dyn Sys,
    platform: Option<Platform>,
    args: &[OsString],
    out: &mut dyn Write,
) -> Exit {
    match run_inner(sys, platform, args, out) {
        Ok(code) => Exit { code, msg: String::new() },
        Err(e) => e,
    }
}

fn run_inner(
    sys: &dyn Sys,
    platform: Option<Platform>,
    args: &[OsString],
    out: &mut dyn Write,
) -> Result<i32, Exit> {
    // Needs no root and no platform of the host.
    match args {
        [a] if is(a, "--version") => {
            let _ = writeln!(out, "{}", env!("CARGO_PKG_VERSION"));
            return Ok(0);
        }
        [a] if is(a, "--help") || is(a, "-h") => {
            let _ = write!(out, "{USAGE}");
            return Ok(0);
        }
        [a, b, c] if is(a, "--list-verbs") && is(b, "--platform") => {
            let p = Platform::parse(c).ok_or_else(|| {
                refuse(2, format!("unknown platform '{}' (deb or mac)", verbs::escaped(c)))
            })?;
            for verb in verbs::table(p) {
                let _ = writeln!(out, "{}", verb.name);
            }
            return Ok(0);
        }
        [a, ..] if is(a, "--list-verbs") => {
            return Err(refuse(2, "usage: nice-dns-helper --list-verbs --platform deb|mac"));
        }
        _ => {}
    }

    let platform = platform.ok_or_else(|| refuse(1, "this OS is not supported"))?;

    let (tree, rest): (Option<&OsString>, &[OsString]) = match args {
        [t] if is(t, "--tree") => return Err(refuse(2, "--tree needs a directory")),
        [t, dir, rest @ ..] if is(t, "--tree") => (Some(dir), rest),
        _ => (None, args),
    };
    let Some((verb, verb_args)) = rest.split_first() else {
        return Err(refuse(2, "no verb given"));
    };
    if tree.is_none() && verb_args.iter().any(|a| is(a, "--tree")) {
        return Err(refuse(2, "--tree <dir> must come before the verb"));
    }

    // 1. static grammar
    if let Some(t) = tree {
        if !verbs::plain(t) {
            return Err(refuse(
                2,
                format!("--tree value '{}' contains a NUL or a newline", verbs::escaped(t)),
            ));
        }
        if !verbs::dash_free(t) {
            return Err(refuse(2, format!("--tree value '{}' looks like an option", display(t))));
        }
    }
    let checked = verbs::check(platform, verb, verb_args).map_err(|m| refuse(2, m))?;
    let tree = tree.ok_or_else(|| refuse(2, "--tree is required"))?;

    // 2. caller
    let caller = caller::identify(sys, platform).map_err(|m| refuse(1, m))?;

    // 3. path arguments against the caller's home
    verbs::check_tree(tree, &caller.home, caller.uid).map_err(|m| refuse(2, format!("--tree: {m}")))?;
    for &i in &checked.file_args {
        verbs::check_path(&verb_args[i], &caller.home, caller.uid, Want::File)
            .map_err(|m| refuse(2, format!("verb '{}': {m}", display(verb))))?;
    }

    // 4. root-ops trust
    let root_ops = sys.root_ops_path();
    check_root_held(root_ops, sys.root_uid(), sys.trust_anchor(), ModeRule::Exact(0o755))
        .map_err(|m| refuse(3, format!("root-ops is not trusted: {m}")))?;

    // 5. privilege setup, hardening, exec
    let plan = exec::plan(root_ops, &caller, tree, verb, verb_args);
    sys.exec(&plan).map_err(|m| refuse(3, m))
}

fn main() {
    if let Err(m) = exec::ensure_std_fds() {
        let _ = writeln!(std::io::stderr(), "nice-dns-helper: {m}");
        std::process::exit(3);
    }
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let mut out = std::io::stdout().lock();
    let exit = run(&RealSys, Platform::current(), &args, &mut out);
    let _ = out.flush();
    if !exit.msg.is_empty() {
        let _ = writeln!(std::io::stderr(), "nice-dns-helper: {}", exit.msg);
    }
    std::process::exit(exit.code);
}
