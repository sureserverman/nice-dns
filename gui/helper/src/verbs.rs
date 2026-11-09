//! The verb tables and argument grammars, and the path grammar.
//!
//! The tables are plain data for both platforms and must equal the allow-list
//! of `deb/root-ops` and `mac/root-ops` (plus `version` and `install-helper`,
//! which root-ops gains in the next task). Every token is compared by exact
//! string equality; nothing is split or prefix-matched.

use std::ffi::{OsStr, OsString};
use std::fs;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    Deb,
    Mac,
}

impl Platform {
    /// The platform this binary runs on; `None` for any other OS.
    pub fn current() -> Option<Platform> {
        if cfg!(target_os = "linux") {
            Some(Platform::Deb)
        } else if cfg!(target_os = "macos") {
            Some(Platform::Mac)
        } else {
            None
        }
    }

    pub fn parse(s: &OsStr) -> Option<Platform> {
        match s.as_bytes() {
            b"deb" => Some(Platform::Deb),
            b"mac" => Some(Platform::Mac),
            _ => None,
        }
    }
}

/// The argument grammar of one verb.
#[derive(Debug)]
pub enum Args {
    /// No arguments.
    None,
    /// Exactly one argument, one of these exact words.
    OneOf(&'static [&'static str]),
    /// `<owned>`: one path from the platform's owned list.
    Owned,
    /// `<owned> <absent|->`.
    Restore,
    /// This many regular files, as caller paths (the path grammar applies).
    Files(usize),
}

#[derive(Debug)]
pub struct Verb {
    pub name: &'static str,
    pub args: Args,
}

const fn v(name: &'static str, args: Args) -> Verb {
    Verb { name, args }
}

const DNS_SUBVERBS: &[&str] = &["check", "status", "snapshot", "restore", "discard"];
const AGENT_SUBVERBS: &[&str] = &["check", "status", "snapshot", "restore", "discard", "post"];

pub const DEB_VERBS: &[Verb] = &[
    v("host-packages", Args::None),
    v("podman-upgrade", Args::None),
    v("crun-upgrade", Args::None),
    v("host-setup", Args::None),
    v("host-linger", Args::None),
    v("interrupt-prereqs", Args::None),
    v("pin-setup", Args::None),
    v("pin", Args::None),
    v("profiles-done", Args::None),
    v("profiles-undo", Args::None),
    v("nm-reload", Args::None),
    v("uninstall", Args::None),
    v("dns", Args::OneOf(DNS_SUBVERBS)),
    v("save-previous", Args::Owned),
    v("restore", Args::Restore),
    v("fix-bin-owner", Args::None),
    v("nm-wait-dropin", Args::None),
    v("version", Args::None),
    v("install-helper", Args::Files(2)),
];

pub const MAC_VERBS: &[Verb] = &[
    v("host-prereqs", Args::None),
    v("persist", Args::OneOf(&["haproxy", "socat"])),
    v("teardown", Args::OneOf(&["reinstall", "uninstall"])),
    v("agent", Args::OneOf(AGENT_SUBVERBS)),
    v("save-previous", Args::Owned),
    v("restore", Args::Restore),
    v("version", Args::None),
    v("install-helper", Args::Files(1)),
    v("remove-helper", Args::None),
];

pub const DEB_OWNED: &[&str] = &[
    "/usr/bin/custom-dns-deb",
    "/etc/NetworkManager/dispatcher.d/90-nice-dns-pin",
    "/etc/NetworkManager/dispatcher.d/91-nice-dns-ipv6",
    "/etc/NetworkManager/dispatcher.d/pre-up.d/91-nice-dns-ipv6",
    "/etc/systemd/system/custom-dns-deb.service",
    "/etc/NetworkManager/conf.d/90-nice-dns.conf",
    "/etc/sysctl.d/99-nice-dns-disable-ipv6.conf",
    "/etc/sysctl.d/99-podman-privileged-ports.conf",
    "/etc/systemd/system/NetworkManager-wait-online.service.d/10-wait-for-connectivity.conf",
];

pub const MAC_OWNED: &[&str] = &[
    "/usr/local/sbin/start-container.sh",
    "/usr/local/sbin/start-container-root.sh",
    "/usr/local/sbin/nice-dns-fetch-bridges.sh",
    "/usr/local/sbin/nice-dns-bridge-eval.sh",
    "/etc/sudoers.d/start-container",
];

pub fn table(p: Platform) -> &'static [Verb] {
    match p {
        Platform::Deb => DEB_VERBS,
        Platform::Mac => MAC_VERBS,
    }
}

pub fn owned(p: Platform) -> &'static [&'static str] {
    match p {
        Platform::Deb => DEB_OWNED,
        Platform::Mac => MAC_OWNED,
    }
}

/// Exact byte equality of a token with a word.
pub fn is(tok: &OsStr, word: &str) -> bool {
    tok.as_bytes() == word.as_bytes()
}

fn shown(tok: &OsStr) -> String {
    tok.to_string_lossy().into_owned()
}

/// A token as a refusal shows it: NUL, newline and other control characters
/// escaped, so the message stays one line and names what was refused.
pub fn escaped(tok: &OsStr) -> String {
    tok.to_string_lossy().escape_debug().to_string()
}

/// A token that cannot be carried safely: NUL or newline.
pub fn plain(tok: &OsStr) -> bool {
    !tok.as_bytes().iter().any(|&b| b == 0 || b == b'\n')
}

/// A value that is a path must not look like an option.
pub fn dash_free(tok: &OsStr) -> bool {
    tok.as_bytes().first() != Some(&b'-')
}

/// What the static check found: which argument positions are caller files.
#[derive(Debug, PartialEq, Eq)]
pub struct Checked {
    pub file_args: Vec<usize>,
}

fn one_of(words: &[&str], tok: &OsStr) -> bool {
    words.iter().any(|w| is(tok, w))
}

/// The static grammar of a verb and its fixed-list arguments. `Err` is the
/// message for exit 2.
pub fn check(p: Platform, verb: &OsStr, args: &[OsString]) -> Result<Checked, String> {
    if !plain(verb) {
        return Err(format!("verb '{}' contains a NUL or a newline", escaped(verb)));
    }
    if let Some(a) = args.iter().find(|a| !plain(a)) {
        return Err(format!(
            "verb '{}': argument '{}' contains a NUL or a newline",
            shown(verb),
            escaped(a)
        ));
    }
    if verb.is_empty() {
        return Err("no verb given".to_string());
    }
    let entry = table(p)
        .iter()
        .find(|e| is(verb, e.name))
        .ok_or_else(|| format!("unknown verb '{}'", shown(verb)))?;
    let want = match entry.args {
        Args::None => 0,
        Args::OneOf(_) | Args::Owned => 1,
        Args::Restore => 2,
        Args::Files(n) => n,
    };
    if args.len() != want {
        return Err(format!(
            "verb '{}' takes {} argument(s), got {}",
            entry.name,
            want,
            args.len()
        ));
    }
    let mut file_args = Vec::new();
    match entry.args {
        Args::None => {}
        Args::OneOf(words) => {
            if !one_of(words, &args[0]) {
                return Err(format!(
                    "verb '{}': unknown argument '{}'",
                    entry.name,
                    shown(&args[0])
                ));
            }
        }
        Args::Owned => {
            if !one_of(owned(p), &args[0]) {
                return Err(format!(
                    "verb '{}': '{}' is not a file nice-dns owns",
                    entry.name,
                    shown(&args[0])
                ));
            }
        }
        Args::Restore => {
            if !one_of(owned(p), &args[0]) {
                return Err(format!(
                    "verb '{}': '{}' is not a file nice-dns owns",
                    entry.name,
                    shown(&args[0])
                ));
            }
            if !(is(&args[1], "absent") || is(&args[1], "-")) {
                return Err(format!(
                    "verb '{}': the second argument is 'absent' or '-', not '{}'",
                    entry.name,
                    shown(&args[1])
                ));
            }
        }
        Args::Files(n) => {
            for (i, a) in args.iter().enumerate().take(n) {
                if !dash_free(a) {
                    return Err(format!(
                        "verb '{}': argument '{}' looks like an option",
                        entry.name,
                        shown(a)
                    ));
                }
                file_args.push(i);
            }
        }
    }
    Ok(Checked { file_args })
}

// ------------------------------------------------------------------ paths

/// What the last component of a checked path must be.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Want {
    Dir,
    File,
}

fn components(p: &[u8]) -> Result<Vec<&[u8]>, &'static str> {
    if p.first() != Some(&b'/') {
        return Err("is not an absolute path");
    }
    let mut out = Vec::new();
    for c in p[1..].split(|&b| b == b'/') {
        if c.is_empty() || c == b"." || c == b".." {
            return Err("has an empty, '.' or '..' component");
        }
        out.push(c);
    }
    Ok(out)
}

/// The path grammar. `home` is the caller's home from the password database
/// and `uid` the caller. `Err` is the message for exit 2.
pub fn check_path(path: &OsStr, home: &OsStr, uid: u32, want: Want) -> Result<(), String> {
    let name = shown(path);
    if !plain(path) {
        return Err(format!("'{name}' contains a NUL or a newline"));
    }
    if !dash_free(path) {
        return Err(format!("'{name}' looks like an option"));
    }
    let pc = components(path.as_bytes()).map_err(|m| format!("'{name}' {m}"))?;
    let hc = components(home.as_bytes())
        .map_err(|m| format!("the home '{}' {m}", shown(home)))?;
    if !(pc.len() > hc.len() && pc[..hc.len()] == hc[..]) {
        return Err(format!(
            "'{name}' is not under the caller's home '{}'",
            shown(home)
        ));
    }
    let mut prefix = PathBuf::from("/");
    let last = pc.len() - 1;
    for (i, c) in pc.iter().enumerate() {
        prefix.push(OsStr::from_bytes(c));
        let md = fs::symlink_metadata(&prefix)
            .map_err(|e| format!("cannot stat '{}': {e}", prefix.display()))?;
        if md.file_type().is_symlink() {
            return Err(format!("'{}' is a symlink", prefix.display()));
        }
        if i >= hc.len() {
            // below the home, anyone who could replace a component could
            // replace what is under it
            if i < last && md.uid() != uid && md.uid() != 0 {
                return Err(format!(
                    "'{}' is owned by neither the caller nor root",
                    prefix.display()
                ));
            }
            if md.mode() & 0o022 != 0 {
                return Err(format!(
                    "'{}' is writable by its group or by others",
                    prefix.display()
                ));
            }
        }
        if i < last {
            if !md.is_dir() {
                return Err(format!("'{}' is not a directory", prefix.display()));
            }
            continue;
        }
        match want {
            Want::Dir if !md.is_dir() => {
                return Err(format!("'{name}' is not a directory"));
            }
            Want::File if !md.is_file() => {
                return Err(format!("'{name}' is not a regular file"));
            }
            _ => {}
        }
        if md.uid() != uid {
            return Err(format!("'{name}' is not owned by the caller"));
        }
    }
    Ok(())
}

/// `--tree` must hold `lib/` (a real directory) with `lib/install.sh` a
/// regular, non-symlink file.
pub fn check_tree(tree: &OsStr, home: &OsStr, uid: u32) -> Result<(), String> {
    check_path(tree, home, uid, Want::Dir)?;
    let mut lib = PathBuf::from(OsString::from_vec(tree.as_bytes().to_vec()));
    lib.push("lib");
    match fs::symlink_metadata(&lib) {
        Ok(m) if m.is_dir() => {}
        Ok(m) if m.file_type().is_symlink() => {
            return Err(format!("'{}': lib is a symlink, not a directory", shown(tree)))
        }
        _ => return Err(format!("'{}' holds no lib/install.sh", shown(tree))),
    }
    lib.push("install.sh");
    match fs::symlink_metadata(&lib) {
        Ok(m) if m.is_file() => Ok(()),
        Ok(m) if m.file_type().is_symlink() => {
            Err(format!("'{}': lib/install.sh is a symlink, not a regular file", shown(tree)))
        }
        Ok(_) => Err(format!("'{}': lib/install.sh is not a regular file", shown(tree))),
        Err(_) => Err(format!("'{}' holds no lib/install.sh", shown(tree))),
    }
}
