//! Caller identity: who is asking, as a uid the helper can trust.
//!
//! The caller's name and home come from the password database for that uid,
//! never from the caller's environment or argv.

use std::ffi::{OsStr, OsString};
use std::io::Read;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;

use crate::exec::{check_root_held, ModeRule, Sys};
use crate::verbs::Platform;

/// A password-database entry.
#[derive(Clone, Debug)]
pub struct Passwd {
    pub uid: u32,
    pub gid: u32,
    pub name: String,
    pub home: OsString,
}

/// The identified caller.
#[derive(Clone, Debug)]
pub struct Caller {
    pub uid: u32,
    pub name: String,
    pub home: OsString,
}

/// A decimal uid: digits only (no sign, no space), at most 10, fits u32 and is
/// not `(uid_t)-1`.
pub fn parse_uid(raw: &[u8]) -> Result<u32, String> {
    if raw.is_empty() || raw.len() > 10 || !raw.iter().all(u8::is_ascii_digit) {
        return Err(format!("'{}' is not a decimal uid", String::from_utf8_lossy(raw)));
    }
    let s = std::str::from_utf8(raw).map_err(|_| "not a decimal uid".to_string())?;
    let uid: u32 = s
        .parse()
        .map_err(|_| format!("'{s}' is not a decimal uid"))?;
    if uid == u32::MAX {
        return Err(format!("'{s}' is not a valid uid"));
    }
    Ok(uid)
}

/// The user names `root-ops` accepts: not empty, not `root`, no leading `-`,
/// only `[A-Za-z0-9._-]`, not all digits.
pub fn name_ok(name: &str) -> bool {
    !name.is_empty()
        && name != "root"
        && !name.starts_with('-')
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-')
        && !name.bytes().all(|b| b.is_ascii_digit())
}

fn finish(uid: u32, pw: Passwd) -> Result<Caller, String> {
    if pw.uid != uid || uid == 0 {
        return Err(format!("the password database gives uid {} for {uid}", pw.uid));
    }
    if !name_ok(&pw.name) {
        return Err(format!("user name '{}' is not one root-ops accepts", pw.name));
    }
    let home: &OsStr = &pw.home;
    if home.as_bytes().first() != Some(&b'/') {
        return Err(format!("the home of '{}' is not an absolute path", pw.name));
    }
    if home.as_bytes().iter().any(|&b| b == 0 || b == b'\n') {
        return Err(format!("the home of '{}' contains a NUL or a newline", pw.name));
    }
    Ok(Caller { uid, name: pw.name, home: pw.home })
}

fn linux(sys: &dyn Sys) -> Result<Caller, String> {
    if sys.euid() != 0 || sys.ruid() != 0 {
        return Err("must run as root through pkexec (real and effective uid are not both 0)".into());
    }
    let raw = sys
        .pkexec_uid()
        .ok_or_else(|| "PKEXEC_UID is not set; run through pkexec".to_string())?;
    let uid = parse_uid(raw.as_bytes()).map_err(|m| format!("PKEXEC_UID: {m}"))?;
    if uid == 0 {
        return Err("PKEXEC_UID is 0; the helper serves a non-root user".into());
    }
    let pw = sys
        .passwd(uid)
        .ok_or_else(|| format!("PKEXEC_UID: no user with uid {uid}"))?;
    finish(uid, pw)
}

/// The uid in the root-held owner file: decimal digits and exactly one
/// newline.
fn read_owner(sys: &dyn Sys) -> Result<u32, String> {
    let path = sys.owner_file_path();
    check_root_held(path, sys.root_uid(), sys.trust_anchor(), ModeRule::NoGroupOtherWrite)
        .map_err(|m| format!("owner file: {m}"))?;
    let mut f = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|e| format!("owner file '{}': {e}", path.display()))?;
    let mut buf = Vec::new();
    f.by_ref()
        .take(32)
        .read_to_end(&mut buf)
        .map_err(|e| format!("owner file '{}': {e}", path.display()))?;
    let digits = buf
        .strip_suffix(b"\n")
        .ok_or_else(|| "owner file: not a uid and one newline".to_string())?;
    parse_uid(digits).map_err(|m| format!("owner file: {m}"))
}

fn mac(sys: &dyn Sys) -> Result<Caller, String> {
    if sys.euid() != 0 {
        return Err("the helper is not setuid root (effective uid is not 0)".into());
    }
    let uid = sys.ruid();
    if uid == 0 {
        return Err("the caller is root; the helper serves a non-root user".into());
    }
    let owner = read_owner(sys)?;
    if owner != uid {
        return Err(format!("uid {uid} is not the user who installed the helper"));
    }
    let pw = sys
        .passwd(uid)
        .ok_or_else(|| format!("no user with uid {uid}"))?;
    if !sys.is_admin(&pw) {
        return Err(format!("user '{}' is not an admin", pw.name));
    }
    finish(uid, pw)
}

/// Who is asking, or why the request is refused (exit 1).
pub fn identify(sys: &dyn Sys, platform: Platform) -> Result<Caller, String> {
    match platform {
        Platform::Deb => linux(sys),
        Platform::Mac => mac(sys),
    }
}
