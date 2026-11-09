//! Unit tests: the whole decision flow driven through a `Sys` double.
//!
//! The double (`Mock`) exists only in this `#[cfg(test)]` module; the shipped
//! binary has no override. Its `exec` runs the program with `bash` in a child
//! process without the setuid step, against a fake root-ops that records its
//! argv and environment. Every refusal test asserts the fake never ran (no
//! marker file) and the double's exec was never called.
//!
//! Run as a non-root user: the fixtures are owned by the test user, who plays
//! "root" for the trust checks (`Mock::root_uid`) and "the caller" for the
//! path checks.

use std::cell::Cell;
use std::ffi::OsString;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};

use crate::caller::{name_ok, parse_uid, Passwd};
use crate::exec::{self, ExecPlan, Sys};
use crate::verbs::{self, Platform};
use crate::{run, Exit};

use Platform::{Deb, Mac};

// ------------------------------------------------------------------ fixture

static COUNTER: AtomicU32 = AtomicU32::new(0);

const FAKE_ROOT_OPS: &str = r#"#!/bin/bash
d="${0%/*}"
: > "$d/marker"
printf '%s\0' "$@" > "$d/argv"
for v in $(compgen -e); do printf '%s=%s\0' "$v" "${!v}"; done > "$d/env"
[ -r /proc/$$/cmdline ] && cat /proc/$$/cmdline > "$d/cmdline"
exit 0
"#;

fn mode(p: &Path, m: u32) {
    fs::set_permissions(p, fs::Permissions::from_mode(m)).unwrap();
}

/// Create a directory and every missing parent, each with mode 0755 whatever
/// the umask (the below-home rule refuses group/other-writable components;
/// tests run on threads, so no process-wide umask call is used).
fn mkdirs(p: impl AsRef<Path>) {
    let p = p.as_ref();
    let mut missing: Vec<&Path> = p.ancestors().take_while(|a| !a.exists()).collect();
    fs::create_dir_all(p).unwrap();
    missing.reverse();
    for d in missing {
        mode(d, 0o755);
    }
}

/// Write a new file with mode 0644 whatever the umask.
fn put(p: impl AsRef<Path>, content: impl AsRef<[u8]>) {
    fs::write(p.as_ref(), content).unwrap();
    mode(p.as_ref(), 0o644);
}

struct Fx {
    base: PathBuf,
    home: PathBuf,
    tree: PathBuf,
    libexec: PathBuf,
    me: u32,
}

impl Fx {
    fn new() -> Fx {
        // SAFETY: getuid cannot fail.
        let me = unsafe { libc::getuid() };
        assert_ne!(me, 0, "run these tests as a non-root user");
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let base = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("nd-helper-{}-{n}", std::process::id()));
        let home = base.join("home").join("alice");
        let tree = home.join("tree");
        let libexec = base.join("libexec").join("nice-dns");
        mkdirs(&base);
        mode(&base, 0o755);
        mkdirs(tree.join("lib"));
        put(tree.join("lib/install.sh"), "# fixture\n");
        // the umask of the machine running the tests must not matter
        for d in [&home, &tree, &tree.join("lib")] {
            mode(d, 0o755);
        }
        mkdirs(&libexec);
        mode(&base.join("libexec"), 0o755);
        mode(&libexec, 0o755);
        fs::write(libexec.join("root-ops"), FAKE_ROOT_OPS).unwrap();
        mode(&libexec.join("root-ops"), 0o755);
        fs::write(libexec.join("owner"), format!("{me}\n")).unwrap();
        mode(&libexec.join("owner"), 0o644);
        Fx { base, home, tree, libexec, me }
    }

    fn root_ops(&self) -> PathBuf {
        self.libexec.join("root-ops")
    }
    fn owner(&self) -> PathBuf {
        self.libexec.join("owner")
    }
    fn marker(&self) -> PathBuf {
        self.libexec.join("marker")
    }

    /// A caller file under home (for install-helper).
    fn file(&self, name: &str) -> PathBuf {
        let p = self.home.join(name);
        fs::write(&p, "x").unwrap();
        mode(&p, 0o644);
        p
    }

    fn mock(&self, platform: Platform) -> Mock {
        let alice = Passwd {
            uid: self.me,
            gid: 100,
            name: "alice".into(),
            home: self.home.clone().into(),
        };
        Mock {
            ruid: if platform == Deb { 0 } else { self.me },
            euid: 0,
            pkexec: if platform == Deb { Some(self.me.to_string().into()) } else { None },
            users: vec![alice],
            admin: true,
            root_ops: self.root_ops(),
            owner_file: self.owner(),
            root_uid: self.me,
            anchor: self.base.clone(),
            execs: Cell::new(0),
        }
    }
}

impl Drop for Fx {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.base);
    }
}

struct Mock {
    ruid: u32,
    euid: u32,
    pkexec: Option<OsString>,
    users: Vec<Passwd>,
    admin: bool,
    root_ops: PathBuf,
    owner_file: PathBuf,
    root_uid: u32,
    anchor: PathBuf,
    execs: Cell<u32>,
}

impl Sys for Mock {
    fn ruid(&self) -> u32 {
        self.ruid
    }
    fn euid(&self) -> u32 {
        self.euid
    }
    fn pkexec_uid(&self) -> Option<OsString> {
        self.pkexec.clone()
    }
    fn passwd(&self, uid: u32) -> Option<Passwd> {
        self.users.iter().find(|u| u.uid == uid).cloned()
    }
    fn is_admin(&self, _user: &Passwd) -> bool {
        self.admin
    }
    fn root_ops_path(&self) -> &Path {
        &self.root_ops
    }
    fn owner_file_path(&self) -> &Path {
        &self.owner_file
    }
    fn root_uid(&self) -> u32 {
        self.root_uid
    }
    fn trust_anchor(&self) -> &Path {
        &self.anchor
    }
    /// Runs the plan in a child without the setuid step.
    fn exec(&self, plan: &ExecPlan) -> Result<i32, String> {
        self.execs.set(self.execs.get() + 1);
        let st = Command::new(&plan.program)
            .args(&plan.args[1..])
            .env_clear()
            .envs(plan.env.iter().map(|(k, v)| (k, v)))
            .status()
            .map_err(|e| e.to_string())?;
        Ok(st.code().unwrap_or(-1))
    }
}

fn strs(v: &[&str]) -> Vec<OsString> {
    v.iter().map(OsString::from).collect()
}

/// `--tree <tree> <rest...>`.
fn cmd(tree: &Path, rest: &[&str]) -> Vec<String> {
    let mut v = vec!["--tree".to_string(), tree.to_str().unwrap().to_string()];
    v.extend(rest.iter().map(|s| s.to_string()));
    v
}

fn go(m: &Mock, p: Platform, args: &[String]) -> Exit {
    let a: Vec<OsString> = args.iter().map(OsString::from).collect();
    let mut out = Vec::new();
    run(m, Some(p), &a, &mut out)
}

/// The run is refused with `code`, the message holds `needle`, and nothing
/// was executed.
fn refused(fx: &Fx, m: &Mock, p: Platform, args: &[String], code: i32, needle: &str) {
    let e = go(m, p, args);
    assert_eq!(e.code, code, "args {args:?}: {}", e.msg);
    assert!(e.msg.contains(needle), "message '{}' lacks '{needle}'", e.msg);
    assert!(e.msg.starts_with(|c: char| c != ' '), "message: {}", e.msg);
    assert_eq!(m.execs.get(), 0, "exec was called for {args:?}");
    assert!(!fx.marker().exists(), "the fake root-ops ran for {args:?}");
}

// ------------------------------------------------------------------ grammar

fn ck(p: Platform, verb: &str, args: &[&str]) -> Result<verbs::Checked, String> {
    verbs::check(p, verb.as_ref(), &strs(args))
}

fn ok(p: Platform, verb: &str, args: &[&str]) {
    if let Err(e) = ck(p, verb, args) {
        panic!("{verb} {args:?} refused: {e}");
    }
}

fn bad(p: Platform, verb: &str, args: &[&str]) {
    assert!(ck(p, verb, args).is_err(), "{verb} {args:?} was accepted");
}

const DEB_ZERO: &[&str] = &[
    "host-packages", "podman-upgrade", "crun-upgrade", "host-setup", "host-linger",
    "interrupt-prereqs", "pin-setup", "pin", "profiles-done", "profiles-undo", "nm-reload",
    "uninstall", "fix-bin-owner", "nm-wait-dropin", "version",
];
const DEB_OWNED: &[&str] = &[
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
const MAC_OWNED: &[&str] = &[
    "/usr/local/sbin/start-container.sh",
    "/usr/local/sbin/start-container-root.sh",
    "/usr/local/sbin/nice-dns-fetch-bridges.sh",
    "/usr/local/sbin/nice-dns-bridge-eval.sh",
    "/etc/sudoers.d/start-container",
];

#[test]
fn grammar_deb_zero_arg_verbs_accepted_and_refuse_any_argument() {
    for v in DEB_ZERO {
        ok(Deb, v, &[]);
        bad(Deb, v, &["x"]);
        bad(Deb, v, &["", ""]);
    }
}

#[test]
fn grammar_deb_dns_subverbs() {
    for s in ["check", "status", "snapshot", "restore", "discard"] {
        ok(Deb, "dns", &[s]);
    }
    bad(Deb, "dns", &[]);
    bad(Deb, "dns", &["check", "status"]);
    bad(Deb, "dns", &["post"]); // an agent word, not a dns word
    bad(Deb, "dns", &["pin"]);
    bad(Deb, "dns", &[""]);
    // exact words only: no spaces, no prefix, no case folding
    for s in ["check status", "check ", " check", "chec", "checks", "Check", "check\t", "status;id"] {
        bad(Deb, "dns", &[s]);
    }
}

#[test]
fn grammar_deb_save_previous_owned_list_only() {
    for p in DEB_OWNED {
        ok(Deb, "save-previous", &[p]);
    }
    bad(Deb, "save-previous", &[]);
    bad(Deb, "save-previous", &[DEB_OWNED[0], DEB_OWNED[1]]);
    for p in [
        "/etc/passwd",
        "/usr/bin/custom-dns-deb/",
        "/usr/bin/custom-dns-deb ",
        "//usr/bin/custom-dns-deb",
        "/usr/bin/../bin/custom-dns-deb",
        "usr/bin/custom-dns-deb",
        "",
        "/usr/local/sbin/start-container.sh", // the mac list
    ] {
        bad(Deb, "save-previous", &[p]);
    }
}

#[test]
fn grammar_deb_restore() {
    for p in DEB_OWNED {
        ok(Deb, "restore", &[p, "absent"]);
        ok(Deb, "restore", &[p, "-"]);
    }
    for second in ["present", "", "--", "ABSENT", "absent ", " absent", "-x", "absen"] {
        bad(Deb, "restore", &[DEB_OWNED[0], second]);
    }
    bad(Deb, "restore", &["/etc/shadow", "absent"]);
    bad(Deb, "restore", &["/etc/shadow", "-"]);
    bad(Deb, "restore", &[]);
    bad(Deb, "restore", &[DEB_OWNED[0]]);
    bad(Deb, "restore", &[DEB_OWNED[0], "-", "-"]);
}

#[test]
fn grammar_deb_install_helper_two_files() {
    let c = ck(Deb, "install-helper", &["/h/bin", "/h/policy"]).unwrap();
    assert_eq!(c.file_args, vec![0, 1]);
    bad(Deb, "install-helper", &[]);
    bad(Deb, "install-helper", &["/h/bin"]);
    bad(Deb, "install-helper", &["/h/bin", "/h/p", "/h/x"]);
    bad(Deb, "install-helper", &["-x", "/h/p"]);
    bad(Deb, "install-helper", &["/h/bin", "--policy"]);
    bad(Deb, "install-helper", &["/h/bin", "-"]);
}

#[test]
fn grammar_mac_zero_arg_verbs() {
    for v in ["host-prereqs", "version", "remove-helper"] {
        ok(Mac, v, &[]);
        bad(Mac, v, &["x"]);
    }
}

#[test]
fn grammar_mac_persist_teardown_agent() {
    for s in ["haproxy", "socat"] {
        ok(Mac, "persist", &[s]);
    }
    for s in ["", "tor", "haproxy ", "socat haproxy", "HAPROXY", "hapro"] {
        bad(Mac, "persist", &[s]);
    }
    bad(Mac, "persist", &[]);
    bad(Mac, "persist", &["haproxy", "socat"]);
    for s in ["reinstall", "uninstall"] {
        ok(Mac, "teardown", &[s]);
    }
    for s in ["", "install", "uninstall now", "reinstal", "Uninstall"] {
        bad(Mac, "teardown", &[s]);
    }
    bad(Mac, "teardown", &[]);
    for s in ["check", "status", "snapshot", "restore", "discard", "post"] {
        ok(Mac, "agent", &[s]);
    }
    for s in ["", "pre", "post ", "check status", "chec", "posts"] {
        bad(Mac, "agent", &[s]);
    }
    bad(Mac, "agent", &[]);
    bad(Mac, "agent", &["post", "check"]);
}

#[test]
fn grammar_mac_save_previous_and_restore() {
    for p in MAC_OWNED {
        ok(Mac, "save-previous", &[p]);
        ok(Mac, "restore", &[p, "absent"]);
        ok(Mac, "restore", &[p, "-"]);
    }
    for p in ["/etc/passwd", "/etc/sudoers.d/start-container ", "/etc/sudoers", DEB_OWNED[0], ""] {
        bad(Mac, "save-previous", &[p]);
        bad(Mac, "restore", &[p, "-"]);
    }
    for second in ["present", "", "--", "absent ", "ABSENT"] {
        bad(Mac, "restore", &[MAC_OWNED[0], second]);
    }
    bad(Mac, "save-previous", &[]);
    bad(Mac, "restore", &[MAC_OWNED[0]]);
    bad(Mac, "restore", &[MAC_OWNED[0], "-", "x"]);
}

#[test]
fn grammar_mac_install_helper_one_file() {
    let c = ck(Mac, "install-helper", &["/h/bin"]).unwrap();
    assert_eq!(c.file_args, vec![0]);
    bad(Mac, "install-helper", &[]);
    bad(Mac, "install-helper", &["/h/bin", "/h/policy"]);
    bad(Mac, "install-helper", &["-f"]);
}

#[test]
fn grammar_verbs_of_the_other_platform_are_unknown() {
    bad(Mac, "host-packages", &[]);
    bad(Mac, "dns", &["check"]);
    bad(Mac, "pin", &[]);
    bad(Deb, "persist", &["haproxy"]);
    bad(Deb, "agent", &["check"]);
    bad(Deb, "host-prereqs", &[]);
    bad(Deb, "teardown", &["uninstall"]);
}

#[test]
fn grammar_unknown_verb_is_named() {
    for p in [Deb, Mac] {
        let e = ck(p, "foo", &[]).unwrap_err();
        assert!(e.contains("unknown verb 'foo'"), "{e}");
        for v in ["", "Pin", "pin ", " pin", "pi", "pins", "pin;id", "--version", "-h"] {
            bad(p, v, &[]);
        }
    }
}

#[test]
fn grammar_nul_and_newline_refused_in_any_token() {
    bad(Deb, "pin\n", &[]);
    bad(Deb, "dns", &["check\n"]);
    bad(Deb, "restore", &[DEB_OWNED[0], "-\n"]);
    let nul = OsString::from(std::ffi::OsStr::from_bytes(b"check\0"));
    assert!(verbs::check(Deb, "dns".as_ref(), &[nul]).is_err());
}

const DEB_NAMES: &[&str] = &[
    "host-packages", "podman-upgrade", "crun-upgrade", "host-setup", "host-linger",
    "interrupt-prereqs", "pin-setup", "pin", "profiles-done", "profiles-undo", "nm-reload",
    "uninstall", "dns", "save-previous", "restore", "fix-bin-owner", "nm-wait-dropin",
    "version", "install-helper",
];
const MAC_NAMES: &[&str] = &[
    "host-prereqs", "persist", "teardown", "agent", "save-previous", "restore", "version",
    "install-helper", "remove-helper",
];

fn sorted(v: &[&str]) -> Vec<String> {
    let mut v: Vec<String> = v.iter().map(|s| s.to_string()).collect();
    v.sort();
    v
}

#[test]
fn tables_hold_exactly_the_brief_verbs_and_owned_lists() {
    let names = |p| sorted(&verbs::table(p).iter().map(|v| v.name).collect::<Vec<_>>());
    assert_eq!(names(Deb), sorted(DEB_NAMES));
    assert_eq!(names(Mac), sorted(MAC_NAMES));
    assert_eq!(verbs::owned(Deb), DEB_OWNED);
    assert_eq!(verbs::owned(Mac), MAC_OWNED);
}

#[test]
fn list_verbs_prints_the_table_for_each_platform_and_version_prints_the_crate_version() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    for (flag, want) in [("deb", DEB_NAMES), ("mac", MAC_NAMES)] {
        let mut out = Vec::new();
        let e = run(&m, None, &strs(&["--list-verbs", "--platform", flag]), &mut out);
        assert_eq!(e.code, 0);
        let got: Vec<&str> = std::str::from_utf8(&out).unwrap().lines().collect();
        assert_eq!(got, want);
    }
    let mut out = Vec::new();
    assert_eq!(run(&m, None, &strs(&["--version"]), &mut out).code, 0);
    assert_eq!(String::from_utf8(out).unwrap(), format!("{}\n", env!("CARGO_PKG_VERSION")));
    let mut out = Vec::new();
    assert_eq!(run(&m, None, &strs(&["--list-verbs", "--platform", "win"]), &mut out).code, 2);
    assert_eq!(m.execs.get(), 0);
}

// ------------------------------------------------------------------ the accepted path

/// bash adds PWD, SHLVL, _ (and may add OLDPWD) to the environment it hands
/// its script; those four are ignored, nothing else is.
fn read_env(fx: &Fx) -> Vec<String> {
    let raw = fs::read(fx.libexec.join("env")).unwrap();
    let mut v: Vec<String> = raw
        .split(|&b| b == 0)
        .filter(|s| !s.is_empty())
        .map(|s| String::from_utf8(s.to_vec()).unwrap())
        .filter(|kv| {
            let k = kv.split('=').next().unwrap();
            !matches!(k, "PWD" | "SHLVL" | "_" | "OLDPWD")
        })
        .collect();
    v.sort();
    v
}

fn read_argv(fx: &Fx) -> Vec<String> {
    let raw = fs::read(fx.libexec.join("argv")).unwrap();
    raw.split(|&b| b == 0)
        .map(|s| String::from_utf8(s.to_vec()).unwrap())
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .skip(1) // the empty tail after the last NUL
        .rev()
        .collect()
}

fn expected_env(fx: &Fx) -> Vec<String> {
    let mut v = vec![
        "PATH=/usr/sbin:/usr/bin:/sbin:/bin".to_string(),
        "ND_ROOT_USER=alice".to_string(),
        format!("ND_ROOT_HOME={}", fx.home.display()),
        format!("ND_ROOT_TREE={}", fx.tree.display()),
    ];
    v.sort();
    v
}

#[test]
fn accepted_linux_root_ops_gets_exactly_the_verb_args_and_four_variables() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    for rest in [
        vec!["host-packages"],
        vec!["dns", "check"],
        vec!["restore", "/usr/bin/custom-dns-deb", "-"],
        vec!["save-previous", "/etc/sysctl.d/99-podman-privileged-ports.conf"],
    ] {
        let _ = fs::remove_file(fx.marker());
        let e = go(&m, Deb, &cmd(&fx.tree, &rest));
        assert_eq!((e.code, e.msg.as_str()), (0, ""));
        assert!(fx.marker().exists());
        assert_eq!(read_argv(&fx), rest);
        assert_eq!(read_env(&fx), expected_env(&fx));
    }
    assert_eq!(m.execs.get(), 4);
}

#[test]
fn accepted_linux_install_helper_passes_both_files() {
    let fx = Fx::new();
    let (bin, pol) = (fx.file("helper-bin"), fx.file("helper.policy"));
    let m = fx.mock(Deb);
    let (b, p) = (bin.to_str().unwrap(), pol.to_str().unwrap());
    let e = go(&m, Deb, &cmd(&fx.tree, &["install-helper", b, p]));
    assert_eq!((e.code, e.msg.as_str()), (0, ""));
    assert_eq!(read_argv(&fx), vec!["install-helper", b, p]);
    assert_eq!(read_env(&fx), expected_env(&fx));
}

#[test]
fn accepted_mac_root_ops_gets_exactly_the_verb_args_and_four_variables() {
    let fx = Fx::new();
    let bin = fx.file("helper-bin");
    let m = fx.mock(Mac);
    for rest in [
        vec!["persist", "socat"],
        vec!["agent", "post"],
        vec!["install-helper", bin.to_str().unwrap()],
    ] {
        let _ = fs::remove_file(fx.marker());
        let e = go(&m, Mac, &cmd(&fx.tree, &rest));
        assert_eq!((e.code, e.msg.as_str()), (0, ""));
        assert_eq!(read_argv(&fx), rest);
        assert_eq!(read_env(&fx), expected_env(&fx));
    }
}

#[test]
fn accepted_exit_status_of_root_ops_passes_through() {
    let fx = Fx::new();
    fs::write(fx.root_ops(), "#!/bin/bash\nexit 4\n").unwrap();
    let m = fx.mock(Deb);
    assert_eq!(go(&m, Deb, &cmd(&fx.tree, &["host-packages"])).code, 4);
}

#[test]
fn plan_is_bash_with_flags_root_ops_verb_args_and_a_four_variable_env() {
    let caller = crate::caller::Caller { uid: 1000, name: "alice".into(), home: "/home/alice".into() };
    let p = exec::plan(
        Path::new("/usr/libexec/nice-dns/root-ops"),
        &caller,
        "/home/alice/t".as_ref(),
        "restore".as_ref(),
        &strs(&["/usr/bin/custom-dns-deb", "-"]),
    );
    assert_eq!(p.program, OsString::from("/bin/bash"));
    assert_eq!(
        p.args,
        strs(&["bash", "--noprofile", "--norc", "/usr/libexec/nice-dns/root-ops", "restore", "/usr/bin/custom-dns-deb", "-"])
    );
    assert_eq!(
        p.env,
        vec![
            ("PATH".into(), "/usr/sbin:/usr/bin:/sbin:/bin".into()),
            ("ND_ROOT_USER".into(), "alice".into()),
            ("ND_ROOT_HOME".into(), "/home/alice".into()),
            ("ND_ROOT_TREE".into(), "/home/alice/t".into()),
        ] as Vec<(OsString, OsString)>
    );
}

#[test]
fn the_shipped_system_has_compiled_in_paths_and_a_real_root_chain() {
    let s = exec::RealSys;
    let want = if cfg!(target_os = "macos") {
        "/usr/local/libexec/nice-dns/root-ops"
    } else {
        "/usr/libexec/nice-dns/root-ops"
    };
    assert_eq!(s.root_ops_path(), Path::new(want));
    assert_eq!(s.owner_file_path(), Path::new("/usr/local/libexec/nice-dns/owner"));
    assert_eq!(s.root_uid(), 0);
    assert_eq!(s.trust_anchor(), Path::new("/"));
}

#[test]
fn the_real_anchor_and_uid_refuse_a_user_owned_chain() {
    let fx = Fx::new();
    let mut m = fx.mock(Deb);
    m.root_uid = 0;
    m.anchor = PathBuf::from("/");
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 3, "root-ops is not trusted");
}

// ------------------------------------------------------------------ path refusals

fn path_case(tree: &Path, needle: &str) {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    refused(&fx, &m, Deb, &cmd(tree, &["host-packages"]), 2, needle);
}

#[test]
fn path_with_dotdot_component_refused() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    let t = format!("{}/../tree", fx.tree.display());
    refused(&fx, &m, Deb, &cmd(Path::new(&t), &["host-packages"]), 2, "'..'");
    let t = format!("{}/./lib/..", fx.tree.display());
    refused(&fx, &m, Deb, &cmd(Path::new(&t), &["host-packages"]), 2, "'.'");
}

#[test]
fn path_with_symlink_as_last_component_refused() {
    let fx = Fx::new();
    let link = fx.home.join("link");
    symlink(&fx.tree, &link).unwrap();
    let m = fx.mock(Deb);
    refused(&fx, &m, Deb, &cmd(&link, &["host-packages"]), 2, "symlink");
}

#[test]
fn path_with_symlink_as_middle_component_refused() {
    let fx = Fx::new();
    let up = fx.home.join("up");
    symlink(&fx.home, &up).unwrap(); // home/up -> home, so home/up/tree is the tree
    let through = up.join("tree");
    assert!(through.join("lib/install.sh").exists());
    let m = fx.mock(Deb);
    refused(&fx, &m, Deb, &cmd(&through, &["host-packages"]), 2, "symlink");
}

#[test]
fn path_with_symlink_as_lib_or_install_sh_refused() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    let real = fx.home.join("real-install.sh");
    put(&real, "x");
    fs::remove_file(fx.tree.join("lib/install.sh")).unwrap();
    symlink(&real, fx.tree.join("lib/install.sh")).unwrap();
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 2, "lib/install.sh");

    let fx = Fx::new();
    let m = fx.mock(Deb);
    let elsewhere = fx.home.join("elsewhere");
    mkdirs(&elsewhere);
    put(elsewhere.join("install.sh"), "x");
    fs::remove_dir_all(fx.tree.join("lib")).unwrap();
    symlink(&elsewhere, fx.tree.join("lib")).unwrap();
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 2, "lib/install.sh");
}

#[test]
fn path_outside_home_refused() {
    let fx = Fx::new();
    let other = fx.base.join("other/tree");
    mkdirs(other.join("lib"));
    put(other.join("lib/install.sh"), "x");
    let m = fx.mock(Deb);
    refused(&fx, &m, Deb, &cmd(&other, &["host-packages"]), 2, "not under the caller's home");
}

#[test]
fn path_in_a_home_with_the_same_prefix_refused() {
    // /home/alice2 is not under /home/alice
    let fx = Fx::new();
    let sibling = fx.base.join("home/alice2/tree");
    mkdirs(sibling.join("lib"));
    put(sibling.join("lib/install.sh"), "x");
    assert!(sibling.to_str().unwrap().starts_with(fx.home.to_str().unwrap()));
    let m = fx.mock(Deb);
    refused(&fx, &m, Deb, &cmd(&sibling, &["host-packages"]), 2, "not under the caller's home");
}

#[test]
fn path_equal_to_home_refused() {
    let fx = Fx::new();
    mkdirs(fx.home.join("lib"));
    put(fx.home.join("lib/install.sh"), "x");
    let m = fx.mock(Deb);
    refused(&fx, &m, Deb, &cmd(&fx.home, &["host-packages"]), 2, "not under the caller's home");
}

#[test]
fn path_not_owned_by_the_caller_refused() {
    let fx = Fx::new();
    let mut m = fx.mock(Deb);
    let other = fx.me + 1;
    m.users = vec![Passwd { uid: other, gid: 100, name: "alice".into(), home: fx.home.clone().into() }];
    m.pkexec = Some(other.to_string().into());
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 2, "not owned by the caller");
}

#[test]
fn path_install_helper_file_not_owned_by_the_caller_refused() {
    // A file owned by the test user is foreign to any other caller uid.
    let fx = Fx::new();
    let bin = fx.file("b");
    let (f, h) = (bin.as_os_str(), fx.home.as_os_str());
    verbs::check_path(f, h, fx.me, verbs::Want::File).unwrap();
    let e = verbs::check_path(f, h, fx.me + 1, verbs::Want::File).unwrap_err();
    assert!(e.contains("not owned by the caller"), "{e}");
}

#[test]
fn path_tree_without_lib_install_sh_refused() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    fs::remove_file(fx.tree.join("lib/install.sh")).unwrap();
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 2, "lib/install.sh");

    let fx = Fx::new();
    let m = fx.mock(Deb);
    fs::remove_dir_all(fx.tree.join("lib")).unwrap();
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 2, "lib/install.sh");

    let fx = Fx::new();
    let m = fx.mock(Deb);
    fs::remove_file(fx.tree.join("lib/install.sh")).unwrap();
    mkdirs(fx.tree.join("lib/install.sh"));
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 2, "lib/install.sh");
}

#[test]
fn path_relative_or_malformed_refused() {
    for t in [
        "tree", "./tree", "home/alice/tree", "", "~/tree", "/", "//", "/home//alice",
    ] {
        path_case(Path::new(t), "");
    }
    let fx = Fx::new();
    let m = fx.mock(Deb);
    let trailing = format!("{}/", fx.tree.display());
    refused(&fx, &m, Deb, &cmd(Path::new(&trailing), &["host-packages"]), 2, "empty");
    let doubled = format!("{}//tree", fx.home.display());
    refused(&fx, &m, Deb, &cmd(Path::new(&doubled), &["host-packages"]), 2, "empty");
    refused(&fx, &m, Deb, &cmd(Path::new("tree"), &["host-packages"]), 2, "absolute");
}

#[test]
fn path_that_is_a_file_not_a_directory_refused() {
    let fx = Fx::new();
    let f = fx.file("plain");
    let m = fx.mock(Deb);
    refused(&fx, &m, Deb, &cmd(&f, &["host-packages"]), 2, "not a directory");
}

#[test]
fn path_install_helper_files_are_checked() {
    let fx = Fx::new();
    let good = fx.file("good");
    let m = fx.mock(Deb);
    let g = good.to_str().unwrap();
    let link = fx.home.join("lnk");
    symlink(&good, &link).unwrap();
    let outside = fx.base.join("outside");
    put(&outside, "x");
    let dir = fx.home.join("adir");
    mkdirs(&dir);
    for (bad_arg, needle) in [
        (link.to_str().unwrap().to_string(), "symlink"),
        (outside.to_str().unwrap().to_string(), "not under the caller's home"),
        (dir.to_str().unwrap().to_string(), "not a regular file"),
        (format!("{}/missing", fx.home.display()), "cannot stat"),
        (format!("{}/../good", fx.home.display()), "'..'"),
        ("relative".to_string(), "absolute"),
    ] {
        refused(&fx, &m, Deb, &cmd(&fx.tree, &["install-helper", g, &bad_arg]), 2, needle);
        refused(&fx, &m, Deb, &cmd(&fx.tree, &["install-helper", &bad_arg, g]), 2, needle);
    }
    let m = fx.mock(Mac);
    refused(&fx, &m, Mac, &cmd(&fx.tree, &["install-helper", link.to_str().unwrap()]), 2, "symlink");
}

#[test]
fn path_dash_nul_and_newline_arguments_refused_before_the_caller_is_looked_at() {
    // A bad caller (no PKEXEC_UID) would give exit 1; the static grammar goes first.
    let fx = Fx::new();
    let mut m = fx.mock(Deb);
    m.pkexec = None;
    refused(&fx, &m, Deb, &cmd(Path::new("-x"), &["host-packages"]), 2, "option");
    refused(&fx, &m, Deb, &cmd(Path::new("/h/a\nb"), &["host-packages"]), 2, "newline");
    let nul = OsString::from(std::ffi::OsStr::from_bytes(b"/h/a\0b"));
    let a = vec![OsString::from("--tree"), nul, OsString::from("host-packages")];
    let mut out = Vec::new();
    assert_eq!(run(&m, Some(Deb), &a, &mut out).code, 2);
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["install-helper", "-x", "/h/y"]), 2, "option");
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["install-helper", "/h/y", "a\nb"]), 2, "newline");
}

// ------------------------------------------------------------------ order and CLI shape

#[test]
fn cli_unknown_verb_is_exit_2_and_named_even_for_a_bad_caller() {
    let fx = Fx::new();
    let mut m = fx.mock(Deb);
    m.pkexec = None;
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["foo"]), 2, "unknown verb 'foo'");
    refused(&fx, &m, Deb, &["foo".to_string()], 2, "unknown verb 'foo'");
}

#[test]
fn cli_tree_is_required_and_needs_a_value() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    refused(&fx, &m, Deb, &["host-packages".to_string()], 2, "--tree is required");
    refused(&fx, &m, Deb, &["--tree".to_string()], 2, "--tree needs");
    refused(&fx, &m, Deb, &["--tree".to_string(), fx.tree.to_str().unwrap().to_string()], 2, "no verb");
    refused(&fx, &m, Deb, &[], 2, "no verb");
    // wrong arg count is refused
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages", "x"]), 2, "takes 0 argument");
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["dns"]), 2, "takes 1 argument");
}

#[test]
fn cli_unsupported_os_is_refused_as_a_caller_problem() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    let e = run(&m, None, &strs(&["--tree", "/x", "pin"]), &mut Vec::new());
    assert_eq!(e.code, 1);
}

#[test]
fn order_caller_is_refused_before_paths_are_looked_at() {
    let fx = Fx::new();
    let mut m = fx.mock(Deb);
    m.pkexec = None;
    refused(&fx, &m, Deb, &cmd(Path::new("/nonexistent/tree"), &["host-packages"]), 1, "PKEXEC_UID");
}

#[test]
fn order_paths_are_refused_before_root_ops_trust() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    mode(&fx.root_ops(), 0o777);
    refused(&fx, &m, Deb, &cmd(Path::new("/nonexistent/tree"), &["host-packages"]), 2, "");
}

// ------------------------------------------------------------------ caller refusals

#[test]
fn caller_linux_pkexec_uid_unset_or_malformed_or_root_or_unknown_refused() {
    let fx = Fx::new();
    let big = (u64::from(u32::MAX) + 1).to_string();
    let cases: Vec<Option<&str>> = vec![
        None, Some(""), Some("abc"), Some("0"), Some("00"), Some("1000x"), Some(" 1000"),
        Some("1000 "), Some("+1000"), Some("-1"), Some("1e3"), Some("0x10"), Some("4294967295"),
        Some(&big), Some("99999999999999999999"), Some("4242424"),
    ];
    for c in cases {
        let mut m = fx.mock(Deb);
        m.pkexec = c.map(OsString::from);
        refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 1, "");
    }
    let mut m = fx.mock(Deb);
    m.pkexec = Some(OsString::from(std::ffi::OsStr::from_bytes(b"\xff")));
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 1, "PKEXEC_UID");
    let mut m = fx.mock(Deb);
    m.pkexec = None;
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 1, "PKEXEC_UID is not set");
    m.pkexec = Some("0".into());
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 1, "PKEXEC_UID is 0");
    m.pkexec = Some("4242424".into());
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 1, "no user");
}

#[test]
fn caller_linux_needs_real_and_effective_root() {
    let fx = Fx::new();
    let mut m = fx.mock(Deb);
    m.euid = fx.me;
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 1, "pkexec");
    let mut m = fx.mock(Deb);
    m.ruid = fx.me;
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 1, "pkexec");
}

#[test]
fn caller_name_and_home_root_ops_would_refuse_are_refused() {
    let fx = Fx::new();
    for name in ["", "root", "-alice", "al ice", "al/ice", "al;ice", "1234", "ali\nce", "ålice"] {
        let mut m = fx.mock(Deb);
        m.users[0].name = name.to_string();
        refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 1, "user name");
    }
    for home in ["", "home/alice", "./alice"] {
        let mut m = fx.mock(Deb);
        m.users[0].home = home.into();
        refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 1, "home");
    }
    for ok_name in ["alice", "a.b-c_d", "user1", "1abc"] {
        assert!(name_ok(ok_name), "{ok_name}");
    }
}

#[test]
fn caller_uid_parser_is_strict_decimal() {
    assert_eq!(parse_uid(b"1000").unwrap(), 1000);
    assert_eq!(parse_uid(b"007").unwrap(), 7);
    for s in ["", "-1", "+1", " 1", "1 ", "1.0", "a", "4294967295", "4294967296", "12345678901"] {
        assert!(parse_uid(s.as_bytes()).is_err(), "{s:?}");
    }
}

#[test]
fn caller_mac_root_or_non_setuid_refused() {
    let fx = Fx::new();
    let mut m = fx.mock(Mac);
    m.ruid = 0;
    refused(&fx, &m, Mac, &cmd(&fx.tree, &["host-prereqs"]), 1, "root");
    let mut m = fx.mock(Mac);
    m.euid = fx.me;
    refused(&fx, &m, Mac, &cmd(&fx.tree, &["host-prereqs"]), 1, "setuid");
}

#[test]
fn caller_mac_owner_file_must_name_the_caller() {
    let fx = Fx::new();
    let other = format!("{}\n", fx.me + 1);
    fs::write(fx.owner(), other).unwrap();
    let m = fx.mock(Mac);
    refused(&fx, &m, Mac, &cmd(&fx.tree, &["host-prereqs"]), 1, "installed the helper");
}

#[test]
fn caller_mac_owner_file_missing_or_malformed_refused() {
    let fx = Fx::new();
    let m = fx.mock(Mac);
    fs::remove_file(fx.owner()).unwrap();
    refused(&fx, &m, Mac, &cmd(&fx.tree, &["host-prereqs"]), 1, "owner file");
    let me = fx.me;
    for content in [
        format!("{me}"),
        format!("{me}\n\n"),
        format!(" {me}\n"),
        format!("{me} \n"),
        format!("{me}\r\n"),
        format!("+{me}\n"),
        "\n".to_string(),
        String::new(),
        format!("{me}\n{me}\n"),
        "abc\n".to_string(),
        format!("{me}{}\n", "0".repeat(40)),
    ] {
        fs::write(fx.owner(), &content).unwrap();
        mode(&fx.owner(), 0o644);
        refused(&fx, &m, Mac, &cmd(&fx.tree, &["host-prereqs"]), 1, "");
    }
}

#[test]
fn caller_mac_owner_file_not_root_owned_refused() {
    let fx = Fx::new();
    let mut m = fx.mock(Mac);
    m.root_uid = fx.me + 1; // the fixture is owned by the test user, who is now "not root"
    refused(&fx, &m, Mac, &cmd(&fx.tree, &["host-prereqs"]), 1, "not owned by root");
}

#[test]
fn caller_mac_owner_file_writable_or_symlink_refused() {
    let fx = Fx::new();
    let m = fx.mock(Mac);
    for md in [0o664, 0o646, 0o666, 0o622, 0o620, 0o602] {
        mode(&fx.owner(), md);
        refused(&fx, &m, Mac, &cmd(&fx.tree, &["host-prereqs"]), 1, "writable");
    }
    mode(&fx.owner(), 0o644);
    let real = fx.libexec.join("owner-real");
    fs::rename(fx.owner(), &real).unwrap();
    symlink(&real, fx.owner()).unwrap();
    refused(&fx, &m, Mac, &cmd(&fx.tree, &["host-prereqs"]), 1, "symlink");
}

#[test]
fn caller_mac_owner_directory_writable_refused() {
    let fx = Fx::new();
    let m = fx.mock(Mac);
    mode(&fx.libexec, 0o777);
    refused(&fx, &m, Mac, &cmd(&fx.tree, &["host-prereqs"]), 1, "writable");
    mode(&fx.libexec, 0o755);
    mode(&fx.base.join("libexec"), 0o775);
    refused(&fx, &m, Mac, &cmd(&fx.tree, &["host-prereqs"]), 1, "writable");
}

#[test]
fn caller_mac_non_admin_refused() {
    let fx = Fx::new();
    let mut m = fx.mock(Mac);
    m.admin = false;
    refused(&fx, &m, Mac, &cmd(&fx.tree, &["host-prereqs"]), 1, "not an admin");
}

#[test]
fn caller_mac_owner_check_comes_before_the_admin_check_and_unknown_user_refused() {
    let fx = Fx::new();
    let mut m = fx.mock(Mac);
    m.users.clear();
    refused(&fx, &m, Mac, &cmd(&fx.tree, &["host-prereqs"]), 1, "no user");
}

#[test]
fn caller_real_group_membership_primary_secondary_and_absent() {
    // SAFETY: getuid cannot fail.
    let Some(me) = exec::RealSys.passwd(unsafe { libc::getuid() }) else {
        return; // no passwd entry in this sandbox
    };
    // the primary gid
    assert!(exec::in_group(&me.name, me.gid, me.gid));
    // a gid nobody has as a group
    assert!(!exec::in_group(&me.name, me.gid, 4_000_000_123));
    assert_eq!(exec::group_gid("no-such-group-nice-dns"), None);
    // A secondary gid, which only the getgrouplist branch can find. The
    // process's own supplementary groups (libc::getgroups) are tried first;
    // a sandbox may give a process groups the database does not list the user
    // in, so the gids /etc/group names the user as a member of are the
    // fallback. The test is skipped only when there is no such gid at all.
    // SAFETY: getgroups with 0 asks for the count; then buf has room for n entries.
    let n = unsafe { libc::getgroups(0, std::ptr::null_mut()) };
    let mut buf = vec![0 as libc::gid_t; usize::try_from(n).unwrap_or(0)];
    let got = unsafe { libc::getgroups(n, buf.as_mut_ptr()) };
    assert!(got >= 0);
    let listed: Vec<u32> = fs::read_to_string("/etc/group")
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split(':').collect();
            let member = f.get(3)?.split(',').any(|m| m == me.name);
            let gid: u32 = f.get(2)?.parse().ok()?;
            (member && gid != me.gid).then_some(gid)
        })
        .collect();
    let secondary = buf
        .iter()
        .copied()
        .find(|g| *g != me.gid && listed.contains(g))
        .or_else(|| listed.first().copied());
    let Some(secondary) = secondary else { return };
    assert!(
        exec::in_group(&me.name, me.gid, secondary),
        "getgrouplist did not list secondary gid {secondary} of {}",
        me.name
    );
}

// ------------------------------------------------------------------ root-ops trust

fn trust(fx: &Fx, m: &Mock, needle: &str) {
    refused(fx, m, Deb, &cmd(&fx.tree, &["host-packages"]), 3, needle);
}

#[test]
fn trust_missing_root_ops_refused() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    fs::remove_file(fx.root_ops()).unwrap();
    trust(&fx, &m, "cannot stat");
}

#[test]
fn trust_root_ops_not_owned_by_root_refused() {
    let fx = Fx::new();
    let mut m = fx.mock(Deb);
    m.root_uid = fx.me + 1;
    trust(&fx, &m, "not owned by root");
}

#[test]
fn trust_root_ops_mode_must_be_exactly_0755() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    for md in [0o775, 0o757, 0o777, 0o4755, 0o2755, 0o1755, 0o700, 0o555, 0o644, 0o756, 0o655] {
        // Some sandboxes forbid setuid/setgid chmod; those modes are then
        // covered by `trust_a_real_setuid_binary_is_refused_by_the_mode_rule`.
        if fs::set_permissions(fx.root_ops(), fs::Permissions::from_mode(md)).is_err() {
            assert!(md & 0o6000 != 0, "chmod {md:o} failed");
            continue;
        }
        trust(&fx, &m, "mode");
    }
    mode(&fx.root_ops(), 0o755);
    assert_eq!(go(&m, Deb, &cmd(&fx.tree, &["host-packages"])).code, 0);
}

#[test]
fn trust_a_real_setuid_binary_is_refused_by_the_mode_rule() {
    use std::os::unix::fs::MetadataExt;
    let su = Path::new("/usr/bin/su");
    let Ok(md) = fs::symlink_metadata(su) else { return };
    if md.mode() & 0o7777 != 0o4755 || md.uid() != 0 {
        return; // not a root-owned 4755 su on this host
    }
    let e = exec::check_root_held(su, 0, Path::new("/"), exec::ModeRule::Exact(0o755)).unwrap_err();
    assert!(e.contains("mode 4755"), "{e}");
    exec::check_root_held(su, 0, Path::new("/"), exec::ModeRule::Exact(0o4755)).unwrap();
}

#[test]
fn trust_mac_flow_refuses_an_untrusted_root_ops_too() {
    let fx = Fx::new();
    let mut m = fx.mock(Mac);
    let other = fx.base.join("rootops2");
    mkdirs(&other);
    mode(&other, 0o755);
    fs::write(other.join("root-ops"), FAKE_ROOT_OPS).unwrap();
    mode(&other.join("root-ops"), 0o775);
    m.root_ops = other.join("root-ops");
    refused(&fx, &m, Mac, &cmd(&fx.tree, &["host-prereqs"]), 3, "mode");
    mode(&other.join("root-ops"), 0o755);
    assert_eq!(go(&m, Mac, &cmd(&fx.tree, &["host-prereqs"])).code, 0);
}

#[test]
fn trust_root_ops_symlink_or_directory_refused() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    let real = fx.libexec.join("real-root-ops");
    fs::rename(fx.root_ops(), &real).unwrap();
    symlink(&real, fx.root_ops()).unwrap();
    trust(&fx, &m, "symlink");
    fs::remove_file(fx.root_ops()).unwrap();
    mkdirs(fx.root_ops());
    trust(&fx, &m, "not a regular file");
}

#[test]
fn trust_writable_parent_refused() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    for md in [0o777, 0o775, 0o757, 0o722, 0o1777] {
        mode(&fx.libexec, md);
        trust(&fx, &m, "writable");
    }
}

#[test]
fn trust_writable_ancestor_refused() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    mode(&fx.base.join("libexec"), 0o775);
    trust(&fx, &m, "writable");
    mode(&fx.base.join("libexec"), 0o755);
    mode(&fx.base, 0o757);
    trust(&fx, &m, "writable"); // the anchor itself is checked too
}

#[test]
fn trust_symlinked_ancestor_and_anchor_not_above_the_path_refused() {
    let fx = Fx::new();
    let mut m = fx.mock(Deb);
    // the root-ops file is "root" but its directories are not
    let outer = fx.base.join("libexec");
    let moved = fx.base.join("moved");
    fs::rename(&outer, &moved).unwrap();
    symlink(&moved, &outer).unwrap();
    trust(&fx, &m, "symlink");
    fs::remove_file(&outer).unwrap();
    fs::rename(&moved, &outer).unwrap();
    m.anchor = fx.base.join("elsewhere");
    trust(&fx, &m, "is not under");
}

#[test]
fn trust_failure_never_execs_even_when_everything_else_passes() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    mode(&fx.root_ops(), 0o775);
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 3, "root-ops is not trusted");
}

#[test]
fn trust_dir_ok_refuses_a_directory_owned_by_someone_else() {
    let fx = Fx::new();
    // fixture dirs are owned by the test user and mode 0755
    exec::dir_ok(&fx.base, fx.me).unwrap();
    let e = exec::dir_ok(&fx.base, fx.me + 1).unwrap_err();
    assert!(e.contains("is not owned by root"), "{e}");
    assert!(!e.contains("writable"), "{e}");
}

#[test]
fn trust_an_ancestor_owned_by_someone_else_refuses_a_file_that_passes_the_owner_check() {
    // The file, its directories up to the base and the base are the test
    // user's ("root" here); the base's parent (/tmp or similar) is not.
    use std::os::unix::fs::MetadataExt;
    let fx = Fx::new();
    let parent = fx.base.parent().unwrap().to_path_buf();
    if fs::metadata(&parent).unwrap().uid() == fx.me {
        return; // a temp dir owned by the test user: nothing foreign to find
    }
    exec::check_root_held(&fx.root_ops(), fx.me, &fx.base, exec::ModeRule::Exact(0o755)).unwrap();
    let e = exec::check_root_held(&fx.root_ops(), fx.me, Path::new("/"), exec::ModeRule::Exact(0o755))
        .unwrap_err();
    assert!(e.contains(&format!("'{}' is not owned by root", parent.display())), "{e}");
}

// ------------------------------------------------------------------ hardening

/// Runs `child` in a forked process and returns its exit status; the closure
/// returns the number of the failed check, 0 for success.
fn in_child(child: impl FnOnce() -> i32) -> i32 {
    // SAFETY: the child calls only libc functions and the code under test
    // (which allocates only on its error paths) and ends in _exit.
    unsafe {
        let pid = libc::fork();
        assert!(pid >= 0);
        if pid == 0 {
            libc::_exit(child());
        }
        let mut status = 0;
        libc::waitpid(pid, &mut status, 0);
        assert!(libc::WIFEXITED(status), "child died: {status}");
        libc::WEXITSTATUS(status)
    }
}

fn get_rl(res: libc::c_int) -> libc::rlimit {
    // SAFETY: zeroed rlimit is a valid out-parameter.
    unsafe {
        let mut r: libc::rlimit = std::mem::zeroed();
        libc::getrlimit(res as _, &mut r);
        r
    }
}

/// Lower a soft limit; false if the system refuses (macOS refuses a stack
/// below its minimum and a data/address-space limit below what is in use).
/// It must not panic: it runs in forked children, where a panic aborts.
fn set_soft(res: libc::c_int, soft: libc::rlim_t) -> bool {
    let mut r = get_rl(res);
    r.rlim_cur = soft;
    // SAFETY: r is live for the call.
    unsafe { libc::setrlimit(res as _, &r) == 0 }
}

/// An open descriptor at a high number (so it is not one of the harness's).
fn high_fd() -> libc::c_int {
    // SAFETY: plain libc calls on fds we own.
    unsafe {
        let n = libc::open(c"/dev/null".as_ptr(), libc::O_RDONLY);
        let hi = libc::fcntl(n, libc::F_DUPFD, 40);
        libc::close(n);
        assert!(hi >= 40);
        hi
    }
}

#[test]
fn harden_resets_inherited_process_state() {
    let leaked = high_fd();
    let code = in_child(|| {
        let fail = |n: i32| -> i32 { n };
        // SAFETY: libc calls with valid arguments, in a forked child.
        unsafe {
            let nofile = libc::RLIMIT_NOFILE as libc::c_int;
            let fsize = libc::RLIMIT_FSIZE as libc::c_int;
            let cpu = libc::RLIMIT_CPU as libc::c_int;
            let memlock = libc::RLIMIT_MEMLOCK as libc::c_int;
            let stack = libc::RLIMIT_STACK as libc::c_int;
            let hard = |r| get_rl(r).rlim_max;
            let h_nofile = hard(nofile);

            libc::close(0);
            libc::signal(libc::SIGPIPE, libc::SIG_IGN);
            libc::signal(libc::SIGUSR2, libc::SIG_IGN);
            libc::umask(0);
            let mut set: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut set);
            libc::sigaddset(&mut set, libc::SIGUSR1);
            libc::sigprocmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
            libc::chdir(c"/tmp".as_ptr());
            // the caller lowers what it can
            for (n, (res, v)) in [(nofile, 3), (fsize, 1 << 20), (cpu, 100_000), (memlock, 1)]
                .into_iter()
                .enumerate()
            {
                if !set_soft(res, v) {
                    return 30 + n as i32; // the setup could not lower it
                }
            }
            // the smallest stack the system accepts, if any
            for v in [64u64 << 10, 1 << 20, 4 << 20] {
                if set_soft(stack, v) {
                    break;
                }
            }
            // lowered to values that cannot hurt the running child
            let others = [
                libc::RLIMIT_AS as libc::c_int,
                libc::RLIMIT_DATA as libc::c_int,
                libc::RLIMIT_NPROC as libc::c_int,
                libc::RLIMIT_RSS as libc::c_int,
            ];
            for (r, v) in others.iter().zip([1u64 << 42, 1 << 42, 1, 1 << 30]) {
                if get_rl(*r).rlim_cur > v {
                    set_soft(*r, v); // may be refused; then it is simply not lowered
                }
            }
            let timer = libc::itimerval {
                it_interval: libc::timeval { tv_sec: 0, tv_usec: 0 },
                it_value: libc::timeval { tv_sec: 1000, tv_usec: 0 },
            };
            libc::setitimer(libc::ITIMER_REAL, &timer, std::ptr::null_mut());

            if crate::exec::harden().is_err() {
                return fail(10);
            }
            if libc::fcntl(leaked, libc::F_GETFD) != -1 {
                return fail(11); // a stray fd survived
            }
            let mut b = [0u8; 1];
            if libc::read(0, b.as_mut_ptr().cast(), 1) != 0 {
                return fail(12); // fd 0 is not /dev/null
            }
            let mut sa: libc::sigaction = std::mem::zeroed();
            libc::sigaction(libc::SIGPIPE, std::ptr::null(), &mut sa);
            if sa.sa_sigaction != libc::SIG_DFL {
                return fail(13);
            }
            libc::sigaction(libc::SIGUSR2, std::ptr::null(), &mut sa);
            if sa.sa_sigaction != libc::SIG_DFL {
                return fail(14);
            }
            let mut cur: libc::sigset_t = std::mem::zeroed();
            libc::sigprocmask(libc::SIG_BLOCK, std::ptr::null(), &mut cur);
            if libc::sigismember(&cur, libc::SIGUSR1) != 0 {
                return fail(15);
            }
            if libc::umask(0o022) != 0o022 {
                return fail(16);
            }
            let mut buf = [0 as libc::c_char; 8];
            if libc::getcwd(buf.as_mut_ptr(), buf.len()).is_null()
                || buf[0] != b'/' as libc::c_char
                || buf[1] != 0
            {
                return fail(17);
            }
            let core = get_rl(libc::RLIMIT_CORE as libc::c_int);
            if core.rlim_cur != 0 || core.rlim_max != 0 {
                return fail(18);
            }
            // limits raised again
            if get_rl(nofile).rlim_cur < h_nofile.min(1024) {
                return fail(19);
            }
            // unlimited, or as high as the (here unprivileged) hard limit allows
            for (res, n) in [(fsize, 20), (cpu, 21), (memlock, 22)] {
                let r = get_rl(res);
                if r.rlim_cur != r.rlim_max {
                    return fail(n);
                }
            }
            for r in others {
                let l = get_rl(r);
                if l.rlim_cur != l.rlim_max {
                    return fail(25);
                }
            }
            let st = get_rl(stack);
            if st.rlim_cur != libc::RLIM_INFINITY && st.rlim_cur < (8u64 << 20).min(st.rlim_max) as libc::rlim_t {
                return fail(23);
            }
            // the alarm is gone
            let mut t: libc::itimerval = std::mem::zeroed();
            libc::getitimer(libc::ITIMER_REAL, &mut t);
            if t.it_value.tv_sec != 0 || t.it_value.tv_usec != 0 {
                return fail(24);
            }
        }
        0
    });
    // SAFETY: closing our own fd.
    unsafe { libc::close(leaked) };
    assert_eq!(code, 0, "hardening check number {code} failed in the child");
}

#[test]
fn harden_close_loop_reaches_an_fd_above_a_lowered_nofile_limit() {
    // The portable (macOS) path: close each number up to the soft limit, which
    // the caller lowered below the fd it holds. Only raising it first helps.
    let leaked = high_fd();
    let code = in_child(|| {
        let nofile = libc::RLIMIT_NOFILE as libc::c_int;
        if !set_soft(nofile, 3) {
            return 3;
        }
        let soft = crate::exec::raise_nofile();
        if soft <= u64::from(leaked as u32) && soft != get_rl(nofile).rlim_max {
            return 1;
        }
        crate::exec::close_from(3, false);
        // SAFETY: F_GETFD on any number is harmless.
        if unsafe { libc::fcntl(leaked, libc::F_GETFD) } != -1 {
            return 2;
        }
        0
    });
    // SAFETY: closing our own fd.
    unsafe { libc::close(leaked) };
    assert_eq!(code, 0, "check {code} failed in the child");
}

// ------------------------------------------------------------------ the real execve

#[test]
fn exec_plan_converts_to_ordered_argv_and_key_value_envp() {
    let caller = crate::caller::Caller { uid: 1, name: "alice".into(), home: "/home/alice".into() };
    let p = exec::plan(
        Path::new("/r/root-ops"),
        &caller,
        "/home/alice/t".as_ref(),
        "restore".as_ref(),
        &strs(&["/usr/bin/custom-dns-deb", "-"]),
    );
    let c = exec::to_c(&p).unwrap();
    assert_eq!(c.program.to_str().unwrap(), "/bin/bash");
    let argv: Vec<&str> = c.argv.iter().map(|a| a.to_str().unwrap()).collect();
    assert_eq!(argv[0], "bash");
    assert_eq!(
        argv,
        ["bash", "--noprofile", "--norc", "/r/root-ops", "restore", "/usr/bin/custom-dns-deb", "-"]
    );
    let envp: Vec<&str> = c.envp.iter().map(|a| a.to_str().unwrap()).collect();
    assert_eq!(
        envp,
        [
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin",
            "ND_ROOT_USER=alice",
            "ND_ROOT_HOME=/home/alice",
            "ND_ROOT_TREE=/home/alice/t",
        ]
    );
}

#[test]
fn exec_conversion_refuses_a_nul_anywhere() {
    let base = ExecPlan {
        program: "/bin/bash".into(),
        args: strs(&["bash", "x"]),
        env: vec![("PATH".into(), "/bin".into())],
    };
    assert!(exec::to_c(&base).is_ok());
    let nul = || OsString::from(std::ffi::OsStr::from_bytes(b"a\0b"));
    let mut p = ExecPlan { program: nul(), ..clone_plan(&base) };
    assert!(exec::to_c(&p).is_err());
    p = ExecPlan { args: vec![nul()], ..clone_plan(&base) };
    assert!(exec::to_c(&p).is_err());
    p = ExecPlan { env: vec![("K".into(), nul())], ..clone_plan(&base) };
    assert!(exec::to_c(&p).is_err());
    p = ExecPlan { env: vec![(nul(), "v".into())], ..clone_plan(&base) };
    assert!(exec::to_c(&p).is_err());
}

fn clone_plan(p: &ExecPlan) -> ExecPlan {
    ExecPlan { program: p.program.clone(), args: p.args.clone(), env: p.env.clone() }
}

#[test]
fn exec_the_real_execve_call_runs_bash_on_root_ops_with_argv_and_env() {
    // The setuid step is skipped (the test is not root); everything else is
    // the shipped path: plan -> CStrings -> execve("/bin/bash", ...).
    let fx = Fx::new();
    let caller = crate::caller::Caller { uid: fx.me, name: "alice".into(), home: fx.home.clone().into() };
    let rest = ["/usr/bin/custom-dns-deb", "-"];
    let plan = exec::plan(&fx.root_ops(), &caller, fx.tree.as_os_str(), "restore".as_ref(), &strs(&rest));
    let code = in_child(|| {
        let _ = exec::do_exec(&plan);
        127 // execve returned
    });
    assert_eq!(code, 0, "the fake root-ops did not run to completion");
    assert!(fx.marker().exists());
    // what root-ops got: the verb and its arguments, in order
    assert_eq!(read_argv(&fx), vec!["restore", rest[0], rest[1]]);
    // and exactly the four variables
    assert_eq!(read_env(&fx), expected_env(&fx));
    // and what bash itself was started with (Linux: its own /proc cmdline)
    if let Ok(raw) = fs::read(fx.libexec.join("cmdline")) {
        let got: Vec<&str> = raw
            .split(|&b| b == 0)
            .filter(|s| !s.is_empty())
            .map(|s| std::str::from_utf8(s).unwrap())
            .collect();
        let root_ops = fx.root_ops();
        assert_eq!(
            got,
            ["bash", "--noprofile", "--norc", root_ops.to_str().unwrap(), "restore", rest[0], rest[1]]
        );
    } else if cfg!(target_os = "linux") {
        panic!("no cmdline recorded on Linux");
    }
}

// ------------------------------------------------------------------ path ownership and mode below home

#[test]
fn path_component_below_home_writable_by_group_or_others_refused() {
    let fx = Fx::new();
    let m = fx.mock(Deb);
    // the tree itself
    for md in [0o775, 0o757, 0o777, 0o722] {
        mode(&fx.tree, md);
        refused(&fx, &m, Deb, &cmd(&fx.tree, &["host-packages"]), 2, "writable");
    }
    mode(&fx.tree, 0o755);
    // a directory between home and the tree
    let deep = fx.home.join("mid/deep");
    mkdirs(deep.join("lib"));
    put(deep.join("lib/install.sh"), "x");
    for d in [&deep, &deep.join("lib")] {
        mode(d, 0o755);
    }
    mode(&fx.home.join("mid"), 0o777);
    refused(&fx, &m, Deb, &cmd(&deep, &["host-packages"]), 2, "writable");
    mode(&fx.home.join("mid"), 0o755);
    assert_eq!(go(&m, Deb, &cmd(&deep, &["host-packages"])).code, 0);
    // a file argument
    let f = fx.file("pol");
    mode(&f, 0o666);
    let m = fx.mock(Deb);
    fs::remove_file(fx.marker()).unwrap();
    refused(&fx, &m, Deb, &cmd(&fx.tree, &["install-helper", f.to_str().unwrap(), f.to_str().unwrap()]), 2, "writable");
}

#[test]
fn path_component_below_home_owned_by_neither_caller_nor_root_refused() {
    // Everything here is the test user's. Treat the caller as uid 0: `alice`
    // (below the home `base/home`) is then owned by neither the caller nor root.
    let fx = Fx::new();
    let home = fx.base.join("home");
    let e = verbs::check_path(fx.tree.as_os_str(), home.as_os_str(), 0, verbs::Want::Dir).unwrap_err();
    assert!(e.contains("owned by neither the caller nor root"), "{e}");
    assert!(e.contains("alice"), "{e}");
    // as the real owner it passes
    verbs::check_path(fx.tree.as_os_str(), home.as_os_str(), fx.me, verbs::Want::Dir).unwrap();
}
