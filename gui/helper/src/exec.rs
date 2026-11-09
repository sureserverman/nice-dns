//! The system seam, the trust check on root-ops, the environment, the process
//! hardening and the exec.
//!
//! `Sys` is everything the decision flow asks of the machine. `RealSys`
//! answers from the real system with compiled-in constants; it has no fields
//! and nothing in it can be overridden. The tests implement `Sys` themselves
//! (`#[cfg(test)]` only).

use std::ffi::{CString, OsStr, OsString};
use std::fs;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::MetadataExt;
use std::path::Path;

use crate::caller::{Caller, Passwd};

pub const ROOT_OPS_LINUX: &str = "/usr/libexec/nice-dns/root-ops";
pub const ROOT_OPS_MAC: &str = "/usr/local/libexec/nice-dns/root-ops";
pub const OWNER_FILE_MAC: &str = "/usr/local/libexec/nice-dns/owner";
pub const BASH: &str = "/bin/bash";
pub const PATH_VALUE: &str = "/usr/sbin:/usr/bin:/sbin:/bin";

/// Everything the decision flow asks of the machine.
pub trait Sys {
    fn ruid(&self) -> u32;
    fn euid(&self) -> u32;
    /// The value of `PKEXEC_UID` (the only variable the helper reads).
    fn pkexec_uid(&self) -> Option<OsString>;
    fn passwd(&self, uid: u32) -> Option<Passwd>;
    /// Whether the user is a member of group `admin`.
    fn is_admin(&self, user: &Passwd) -> bool;
    fn root_ops_path(&self) -> &Path;
    fn owner_file_path(&self) -> &Path;
    /// The uid root-held files must have (0).
    fn root_uid(&self) -> u32;
    /// The topmost directory of a root-held chain that is checked (`/`).
    fn trust_anchor(&self) -> &Path;
    /// Privilege setup, hardening and exec. The real one never returns `Ok`;
    /// a test double may run the program and return its status.
    fn exec(&self, plan: &ExecPlan) -> Result<i32, String>;
}

// ------------------------------------------------------------ trust check

#[derive(Clone, Copy, Debug)]
pub enum ModeRule {
    /// The permission and special bits are exactly this.
    Exact(u32),
    /// Not writable by group or other.
    NoGroupOtherWrite,
}

pub fn dir_ok(path: &Path, root_uid: u32) -> Result<(), String> {
    let md = fs::symlink_metadata(path)
        .map_err(|e| format!("cannot stat '{}': {e}", path.display()))?;
    if md.file_type().is_symlink() {
        return Err(format!("'{}' is a symlink", path.display()));
    }
    if !md.is_dir() {
        return Err(format!("'{}' is not a directory", path.display()));
    }
    if md.uid() != root_uid {
        return Err(format!("'{}' is not owned by root", path.display()));
    }
    if md.mode() & 0o022 != 0 {
        return Err(format!(
            "'{}' is writable by its group or by others",
            path.display()
        ));
    }
    Ok(())
}

/// `path` is a regular non-symlink file owned by `root_uid` whose mode obeys
/// `rule`, and its directory and every ancestor up to and including `anchor`
/// are real directories owned by `root_uid` and not group- or
/// world-writable. (An ancestor that is group-owned by gid 0 is fine because
/// group write is refused outright.)
pub fn check_root_held(
    path: &Path,
    root_uid: u32,
    anchor: &Path,
    rule: ModeRule,
) -> Result<(), String> {
    if !path.is_absolute() || !path.starts_with(anchor) {
        return Err(format!("'{}' is not under '{}'", path.display(), anchor.display()));
    }
    let md = fs::symlink_metadata(path)
        .map_err(|e| format!("cannot stat '{}': {e}", path.display()))?;
    if md.file_type().is_symlink() {
        return Err(format!("'{}' is a symlink", path.display()));
    }
    if !md.is_file() {
        return Err(format!("'{}' is not a regular file", path.display()));
    }
    if md.uid() != root_uid {
        return Err(format!("'{}' is not owned by root", path.display()));
    }
    match rule {
        ModeRule::Exact(m) => {
            if md.mode() & 0o7777 != m {
                return Err(format!(
                    "'{}' has mode {:04o}, not {:04o}",
                    path.display(),
                    md.mode() & 0o7777,
                    m
                ));
            }
        }
        ModeRule::NoGroupOtherWrite => {
            if md.mode() & 0o022 != 0 {
                return Err(format!(
                    "'{}' is writable by its group or by others",
                    path.display()
                ));
            }
        }
    }
    for dir in path.ancestors().skip(1) {
        dir_ok(dir, root_uid)?;
        if dir == anchor {
            break;
        }
    }
    Ok(())
}

// ------------------------------------------------------------ the plan

/// What to exec: a program, its full argv (argv[0] included) and the whole
/// environment.
#[derive(Debug, PartialEq, Eq)]
pub struct ExecPlan {
    pub program: OsString,
    pub args: Vec<OsString>,
    pub env: Vec<(OsString, OsString)>,
}

pub fn plan(root_ops: &Path, caller: &Caller, tree: &OsStr, verb: &OsStr, rest: &[OsString]) -> ExecPlan {
    let mut args: Vec<OsString> = vec![
        "bash".into(),
        "--noprofile".into(),
        "--norc".into(),
        root_ops.as_os_str().to_os_string(),
        verb.to_os_string(),
    ];
    args.extend(rest.iter().cloned());
    ExecPlan {
        program: BASH.into(),
        args,
        env: vec![
            ("PATH".into(), PATH_VALUE.into()),
            ("ND_ROOT_USER".into(), caller.name.clone().into()),
            ("ND_ROOT_HOME".into(), caller.home.clone()),
            ("ND_ROOT_TREE".into(), tree.to_os_string()),
        ],
    }
}

// ------------------------------------------------------------ the real system

pub struct RealSys;

impl Sys for RealSys {
    fn ruid(&self) -> u32 {
        // SAFETY: getuid has no preconditions and cannot fail.
        unsafe { libc::getuid() }
    }

    fn euid(&self) -> u32 {
        // SAFETY: geteuid has no preconditions and cannot fail.
        unsafe { libc::geteuid() }
    }

    fn pkexec_uid(&self) -> Option<OsString> {
        std::env::var_os("PKEXEC_UID")
    }

    fn passwd(&self, uid: u32) -> Option<Passwd> {
        let mut buf = vec![0u8; 1024];
        loop {
            // SAFETY: an all-zero passwd is a valid out-parameter for getpwuid_r.
            let mut pw: libc::passwd = unsafe { std::mem::zeroed() };
            let mut res: *mut libc::passwd = std::ptr::null_mut();
            // SAFETY: pw, buf and res are live for the call; buf.len() is its size.
            let rc = unsafe {
                libc::getpwuid_r(uid, &mut pw, buf.as_mut_ptr().cast(), buf.len(), &mut res)
            };
            if rc == libc::ERANGE && buf.len() < (1 << 20) {
                buf.resize(buf.len() * 2, 0);
                continue;
            }
            if rc != 0 || res.is_null() {
                return None;
            }
            // SAFETY: on success pw_name and pw_dir point at NUL-terminated
            // strings inside buf, which outlives these reads.
            let (name, home) = unsafe {
                (
                    std::ffi::CStr::from_ptr(pw.pw_name).to_string_lossy().into_owned(),
                    OsString::from_vec(std::ffi::CStr::from_ptr(pw.pw_dir).to_bytes().to_vec()),
                )
            };
            return Some(Passwd { uid: pw.pw_uid, gid: pw.pw_gid, name, home });
        }
    }

    fn is_admin(&self, user: &Passwd) -> bool {
        match group_gid("admin") {
            Some(admin) => in_group(&user.name, user.gid, admin),
            None => false,
        }
    }

    fn root_ops_path(&self) -> &Path {
        Path::new(if cfg!(target_os = "macos") { ROOT_OPS_MAC } else { ROOT_OPS_LINUX })
    }

    fn owner_file_path(&self) -> &Path {
        Path::new(OWNER_FILE_MAC)
    }

    fn root_uid(&self) -> u32 {
        0
    }

    fn trust_anchor(&self) -> &Path {
        Path::new("/")
    }

    fn exec(&self, plan: &ExecPlan) -> Result<i32, String> {
        become_root()?;
        harden()?;
        Err(do_exec(plan))
    }
}

fn os_err(what: &str) -> String {
    format!("{what}: {}", std::io::Error::last_os_error())
}

/// The gid of the named group, if it exists.
pub fn group_gid(name: &str) -> Option<u32> {
    let cname = CString::new(name).ok()?;
    let mut buf = vec![0u8; 1024];
    loop {
        // SAFETY: an all-zero group is a valid out-parameter for getgrnam_r.
        let mut gr: libc::group = unsafe { std::mem::zeroed() };
        let mut res: *mut libc::group = std::ptr::null_mut();
        // SAFETY: all pointers are live for the call; buf.len() is its size.
        let rc = unsafe {
            libc::getgrnam_r(cname.as_ptr(), &mut gr, buf.as_mut_ptr().cast(), buf.len(), &mut res)
        };
        if rc == libc::ERANGE && buf.len() < (1 << 20) {
            buf.resize(buf.len() * 2, 0);
            continue;
        }
        if rc != 0 || res.is_null() {
            return None;
        }
        return Some(gr.gr_gid);
    }
}

#[cfg(target_os = "macos")]
type GroupListEntry = libc::c_int;
#[cfg(not(target_os = "macos"))]
type GroupListEntry = libc::gid_t;

/// Whether `target` is `primary` or one of the groups `getgrouplist` gives
/// for `user`. Fails closed when the list cannot be had.
#[allow(clippy::unnecessary_cast)] // the entry is c_int on macOS, gid_t elsewhere
pub fn in_group(user: &str, primary: u32, target: u32) -> bool {
    if primary == target {
        return true;
    }
    let Ok(cname) = CString::new(user) else { return false };
    let mut cap: usize = 64;
    for _ in 0..8 {
        let mut groups: Vec<GroupListEntry> = vec![0; cap];
        let mut n = cap as libc::c_int;
        // SAFETY: groups has room for n entries and n is updated in place.
        let rc = unsafe {
            libc::getgrouplist(cname.as_ptr(), primary as _, groups.as_mut_ptr().cast(), &mut n)
        };
        if rc >= 0 {
            let n = usize::try_from(n).unwrap_or(0).min(groups.len());
            return groups[..n].iter().any(|&g| g as u32 == target);
        }
        cap = cap.saturating_mul(2).max(usize::try_from(n).unwrap_or(0) + 1);
    }
    false
}

// ------------------------------------------------------------ privilege and hardening

/// Real and effective ids all root, supplementary groups just 0, verified.
fn become_root() -> Result<(), String> {
    let groups: [libc::gid_t; 1] = [0];
    // SAFETY: groups is live for the call and holds the one entry we say.
    if unsafe { libc::setgroups(1 as _, groups.as_ptr()) } != 0 {
        return Err(os_err("setgroups"));
    }
    // SAFETY: setgid and setuid take plain ids; we are euid 0 here.
    if unsafe { libc::setgid(0) } != 0 {
        return Err(os_err("setgid"));
    }
    // SAFETY: as above; setuid goes last because it gives up the right to the rest.
    if unsafe { libc::setuid(0) } != 0 {
        return Err(os_err("setuid"));
    }
    // SAFETY: the get*id calls have no preconditions.
    let ok = unsafe {
        libc::getuid() == 0 && libc::geteuid() == 0 && libc::getgid() == 0 && libc::getegid() == 0
    };
    if !ok {
        return Err("real and effective ids are not all root after setuid".to_string());
    }
    Ok(())
}

/// Make fds 0, 1 and 2 open (a closed one becomes /dev/null) so that no later
/// open lands on them. Called first thing in `main` and again before exec.
pub fn ensure_std_fds() -> Result<(), String> {
    for fd in 0..3 {
        // SAFETY: F_GETFD on any fd number is harmless.
        if unsafe { libc::fcntl(fd, libc::F_GETFD) } != -1 {
            continue;
        }
        if std::io::Error::last_os_error().raw_os_error() != Some(libc::EBADF) {
            return Err(os_err("fcntl"));
        }
        // SAFETY: the path is a NUL-terminated literal.
        let n = unsafe { libc::open(c"/dev/null".as_ptr(), libc::O_RDWR) };
        if n != fd {
            if n >= 0 {
                // SAFETY: n is the fd we just opened.
                unsafe { libc::close(n) };
            }
            return Err(format!("cannot reopen fd {fd} on /dev/null"));
        }
    }
    Ok(())
}

/// The NOFILE soft limit the close loop may rely on (capped).
fn nofile_soft() -> libc::c_int {
    // SAFETY: an all-zero rlimit is a valid out-parameter.
    let mut r: libc::rlimit = unsafe { std::mem::zeroed() };
    // SAFETY: r is live for the call.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE as _, &mut r) } != 0 {
        return 1024;
    }
    let cur = if r.rlim_cur == libc::RLIM_INFINITY { 1 << 20 } else { r.rlim_cur.min(1 << 20) };
    cur as libc::c_int
}

/// Close every fd from `first` up. On Linux `close_range` does it in one call
/// (`allow_syscall`); otherwise, and as its fallback, close each number up to
/// the NOFILE soft limit, which `raise_nofile` has raised first.
pub fn close_from(first: libc::c_int, allow_syscall: bool) {
    #[cfg(target_os = "linux")]
    if allow_syscall {
        // SAFETY: close_range takes plain integers; failure (old kernel) falls through.
        let rc = unsafe {
            libc::syscall(
                libc::SYS_close_range,
                first as libc::c_uint,
                libc::c_uint::MAX,
                0 as libc::c_uint,
            )
        };
        if rc == 0 {
            return;
        }
    }
    let _ = allow_syscall;
    for fd in first..nofile_soft() {
        // SAFETY: closing a number that is not open fails with EBADF, harmlessly.
        unsafe { libc::close(fd) };
    }
}

fn rlimit_set(res: libc::c_int, cur: libc::rlim_t, max: libc::rlim_t) -> bool {
    let r = libc::rlimit { rlim_cur: cur, rlim_max: max };
    // SAFETY: r is live for the call.
    unsafe { libc::setrlimit(res as _, &r) == 0 }
}

fn rlimit_get(res: libc::c_int) -> Option<libc::rlimit> {
    // SAFETY: an all-zero rlimit is a valid out-parameter.
    let mut r: libc::rlimit = unsafe { std::mem::zeroed() };
    // SAFETY: r is live for the call.
    (unsafe { libc::getrlimit(res as _, &mut r) } == 0).then_some(r)
}

/// Soft (and, as root, hard) limit to unlimited; where the hard limit cannot
/// be raised, the soft limit up to the hard one.
pub fn raise_unlimited(res: libc::c_int) {
    if rlimit_set(res, libc::RLIM_INFINITY, libc::RLIM_INFINITY) {
        return;
    }
    if let Some(old) = rlimit_get(res) {
        rlimit_set(res, old.rlim_max, old.rlim_max);
    }
}

/// The soft limit at least `min` (a limit that is already larger, or
/// unlimited, stays).
pub fn raise_at_least(res: libc::c_int, min: libc::rlim_t) {
    let Some(old) = rlimit_get(res) else { return };
    if old.rlim_cur == libc::RLIM_INFINITY || old.rlim_cur >= min {
        return;
    }
    if !rlimit_set(res, min, old.rlim_max.max(min)) && old.rlim_max >= min {
        rlimit_set(res, min, old.rlim_max);
    }
}

/// The most descriptors a process may ask for: Linux's default `nr_open`; on
/// macOS `kern.maxfilesperproc`, above which `setrlimit` refuses.
#[cfg(target_os = "macos")]
fn nofile_cap() -> libc::rlim_t {
    let mut v: libc::c_int = 0;
    let mut len = std::mem::size_of::<libc::c_int>();
    // SAFETY: v and len are live for the call and len is v's size.
    let rc = unsafe {
        libc::sysctlbyname(
            c"kern.maxfilesperproc".as_ptr(),
            (&mut v as *mut libc::c_int).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc == 0 && v > 0 { v as libc::rlim_t } else { 10240 }
}
#[cfg(not(target_os = "macos"))]
fn nofile_cap() -> libc::rlim_t {
    1 << 20
}

/// RLIMIT_NOFILE soft limit up to its hard limit, capped (the caller may have
/// lowered it below an fd it holds open). Returns the soft limit now in force.
pub fn raise_nofile() -> libc::rlim_t {
    let cap = nofile_cap();
    let res = libc::RLIMIT_NOFILE as libc::c_int;
    if !rlimit_set(res, cap, cap) {
        if let Some(old) = rlimit_get(res) {
            rlimit_set(res, old.rlim_max.min(cap), old.rlim_max);
        }
    }
    rlimit_get(res).map_or(0, |r| r.rlim_cur)
}

/// Every limit the caller could have lowered to make root-ops die mid-run.
/// CORE is set to 0 by `harden`, after this.
pub fn raise_limits() {
    raise_nofile();
    let c = |r| r as libc::c_int;
    for res in [
        c(libc::RLIMIT_AS),
        c(libc::RLIMIT_DATA),
        c(libc::RLIMIT_NPROC),
        c(libc::RLIMIT_MEMLOCK),
        c(libc::RLIMIT_RSS),
        c(libc::RLIMIT_FSIZE),
        c(libc::RLIMIT_CPU),
    ] {
        raise_unlimited(res);
    }
    #[cfg(target_os = "linux")]
    for res in [c(libc::RLIMIT_SIGPENDING), c(libc::RLIMIT_MSGQUEUE)] {
        raise_unlimited(res);
    }
    raise_at_least(c(libc::RLIMIT_STACK), 8 << 20);
}

/// Everything the child must not inherit. Works unprivileged too, which is
/// how the tests exercise it; as root it can also raise hard limits.
pub fn harden() -> Result<(), String> {
    ensure_std_fds()?;
    raise_limits();
    close_from(3, true);

    // SAFETY: an all-zero sigset is a valid out-parameter; sigemptyset fills it.
    let mut set: libc::sigset_t = unsafe { std::mem::zeroed() };
    // SAFETY: set is live for both calls.
    unsafe {
        libc::sigemptyset(&mut set);
        if libc::sigprocmask(libc::SIG_SETMASK, &set, std::ptr::null_mut()) != 0 {
            return Err(os_err("sigprocmask"));
        }
    }
    for sig in 1..65 {
        if sig == libc::SIGKILL || sig == libc::SIGSTOP {
            continue;
        }
        // SAFETY: SIG_DFL is always a valid disposition; an invalid signal
        // number just fails, which is ignored.
        unsafe { libc::signal(sig, libc::SIG_DFL) };
    }

    // A pending alarm survives execve.
    let zero = libc::itimerval {
        it_interval: libc::timeval { tv_sec: 0, tv_usec: 0 },
        it_value: libc::timeval { tv_sec: 0, tv_usec: 0 },
    };
    for which in [libc::ITIMER_REAL, libc::ITIMER_VIRTUAL, libc::ITIMER_PROF] {
        // SAFETY: zero is live for the call; the old value is not wanted.
        if unsafe { libc::setitimer(which, &zero, std::ptr::null_mut()) } != 0 {
            return Err(os_err("setitimer"));
        }
    }

    // SAFETY: umask takes a plain mode.
    unsafe { libc::umask(0o022) };
    // SAFETY: the path is a NUL-terminated literal.
    if unsafe { libc::chdir(c"/".as_ptr()) } != 0 {
        return Err(os_err("chdir"));
    }

    if !rlimit_set(libc::RLIMIT_CORE as libc::c_int, 0, 0) {
        return Err(os_err("setrlimit(RLIMIT_CORE)"));
    }
    Ok(())
}

/// The plan as the C strings `execve` takes.
#[derive(Debug)]
pub struct CExec {
    pub program: CString,
    pub argv: Vec<CString>,
    pub envp: Vec<CString>,
}

/// Pure conversion of a plan: argv in order (argv[0] included), `KEY=VALUE`
/// environment strings; a NUL anywhere is refused.
pub fn to_c(plan: &ExecPlan) -> Result<CExec, String> {
    let nul = || "an exec string contains a NUL".to_string();
    let program = CString::new(plan.program.as_bytes()).map_err(|_| nul())?;
    let argv = plan
        .args
        .iter()
        .map(|a| CString::new(a.as_bytes()).map_err(|_| nul()))
        .collect::<Result<Vec<_>, _>>()?;
    let envp = plan
        .env
        .iter()
        .map(|(k, v)| {
            let mut kv = k.as_bytes().to_vec();
            kv.push(b'=');
            kv.extend_from_slice(v.as_bytes());
            CString::new(kv).map_err(|_| nul())
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(CExec { program, argv, envp })
}

/// `execve`; only returns on failure, with the message.
pub fn exec_c(c: &CExec) -> String {
    let mut argv_p: Vec<*const libc::c_char> = c.argv.iter().map(|a| a.as_ptr()).collect();
    argv_p.push(std::ptr::null());
    let mut envp_p: Vec<*const libc::c_char> = c.envp.iter().map(|a| a.as_ptr()).collect();
    envp_p.push(std::ptr::null());
    // SAFETY: program, argv_p and envp_p point at NUL-terminated strings owned
    // by `c`, and both pointer arrays end in a null pointer.
    unsafe { libc::execve(c.program.as_ptr(), argv_p.as_ptr(), envp_p.as_ptr()) };
    os_err(&format!("exec {}", c.program.to_string_lossy()))
}

/// Convert and `execve` (no privilege step); only returns on failure.
pub fn do_exec(plan: &ExecPlan) -> String {
    match to_c(plan) {
        Ok(c) => exec_c(&c),
        Err(e) => e,
    }
}
