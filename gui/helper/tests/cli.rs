//! Integration tests on the built binary. None of them needs root.

use std::collections::BTreeSet;
use std::process::{Command, Output};

// The helper's own tables, compiled in so they can be compared to root-ops.
#[allow(dead_code)]
#[path = "../src/verbs.rs"]
mod verbs;

fn helper(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_nice-dns-helper"))
        .args(args)
        .env_remove("PKEXEC_UID")
        .output()
        .expect("run the helper")
}

fn lines(o: &Output) -> Vec<String> {
    String::from_utf8(o.stdout.clone()).unwrap().lines().map(str::to_string).collect()
}

fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

/// The allow-list labels of a root-ops script: the lines of exactly two
/// spaces, a name and `)` (what the stage gate greps for).
fn root_ops_labels(path: &str) -> BTreeSet<String> {
    let full = format!("{}/../../{path}", env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read_to_string(&full).unwrap_or_else(|e| panic!("{full}: {e}"));
    text.lines()
        .filter_map(|l| {
            let rest = l.strip_prefix("  ")?;
            let name: String = rest.chars().take_while(|c| c.is_ascii_lowercase() || *c == '-').collect();
            (!name.is_empty() && rest[name.len()..].starts_with(')')).then_some(name)
        })
        .collect()
}

#[test]
fn version_prints_the_crate_version_and_exits_0() {
    let o = helper(&["--version"]);
    assert_eq!(o.status.code(), Some(0));
    assert_eq!(lines(&o), vec![env!("CARGO_PKG_VERSION")]);
}

#[test]
fn list_verbs_deb_and_mac_print_the_tables_one_name_per_line() {
    let deb = helper(&["--list-verbs", "--platform", "deb"]);
    assert_eq!(deb.status.code(), Some(0));
    assert_eq!(
        lines(&deb),
        [
            "host-packages", "podman-upgrade", "crun-upgrade", "host-setup", "host-linger",
            "interrupt-prereqs", "pin-setup", "pin", "profiles-done", "profiles-undo",
            "nm-reload", "uninstall", "dns", "save-previous", "restore", "fix-bin-owner",
            "nm-wait-dropin", "version", "install-helper",
        ]
    );
    let mac = helper(&["--list-verbs", "--platform", "mac"]);
    assert_eq!(mac.status.code(), Some(0));
    assert_eq!(
        lines(&mac),
        ["host-prereqs", "persist", "teardown", "agent", "save-previous", "restore", "version", "install-helper", "remove-helper"]
    );
}

#[test]
fn list_verbs_needs_a_known_platform() {
    assert_eq!(helper(&["--list-verbs", "--platform", "win"]).status.code(), Some(2));
    assert_eq!(helper(&["--list-verbs"]).status.code(), Some(2));
}

#[test]
fn list_verbs_equal_the_root_ops_allow_lists_plus_the_two_new_verbs() {
    for (platform, script) in [("deb", "deb/root-ops"), ("mac", "mac/root-ops")] {
        let ours: BTreeSet<String> =
            lines(&helper(&["--list-verbs", "--platform", platform])).into_iter().collect();
        let theirs = root_ops_labels(script);
        assert!(!theirs.is_empty(), "no labels read from {script}");
        let missing: Vec<_> = theirs.difference(&ours).collect();
        assert!(missing.is_empty(), "{platform}: in root-ops, not in the helper: {missing:?}");
        let extra: Vec<_> = ours.difference(&theirs).cloned().collect();
        // root-ops gains these two in the next task; after it the sets are equal.
        let allowed = ["install-helper", "version"];
        assert!(
            extra.iter().all(|e| allowed.contains(&e.as_str())),
            "{platform}: in the helper, not in root-ops: {extra:?}"
        );
    }
}

#[test]
fn unknown_verb_exits_2_and_names_the_verb() {
    for args in [vec!["--tree", "/nonexistent", "foo"], vec!["foo"]] {
        let o = helper(&args);
        assert_eq!(o.status.code(), Some(2), "{args:?}");
        assert!(stderr(&o).starts_with("nice-dns-helper: "), "{}", stderr(&o));
        assert!(stderr(&o).contains("unknown verb 'foo'"), "{}", stderr(&o));
        assert!(o.stdout.is_empty());
    }
}

#[test]
fn bad_subverb_and_missing_tree_exit_2() {
    assert_eq!(helper(&["--tree", "/x", "dns", "check status"]).status.code(), Some(2));
    assert_eq!(helper(&["--tree", "/x", "host-packages", "extra"]).status.code(), Some(2));
    assert_eq!(helper(&["--tree", "/x"]).status.code(), Some(2));
    assert_eq!(helper(&[]).status.code(), Some(2));
}

#[test]
fn valid_verb_without_pkexec_uid_or_setuid_exits_1_and_runs_nothing() {
    let verb: &[&str] = if cfg!(target_os = "macos") {
        &["--tree", "/nonexistent", "host-prereqs"]
    } else {
        &["--tree", "/nonexistent", "host-packages"]
    };
    let o = helper(verb);
    assert_eq!(o.status.code(), Some(1), "{}", stderr(&o));
    assert!(stderr(&o).starts_with("nice-dns-helper: "));
    // refused at the caller check: never got as far as the tree or root-ops
    assert!(!stderr(&o).contains("root-ops is not trusted"));
    assert!(!stderr(&o).contains("--tree"));
    assert!(o.stdout.is_empty());
}

fn root_ops_text(path: &str) -> String {
    let full = format!("{}/../../{path}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&full).unwrap_or_else(|e| panic!("{full}: {e}"))
}

/// The words of `fn() { case "$1" in a|b|c) ;; ...` on the function's line.
fn case_words(text: &str, func: &str) -> BTreeSet<String> {
    let line = text
        .lines()
        .find(|l| l.starts_with(&format!("{func}() {{")))
        .unwrap_or_else(|| panic!("no {func} in root-ops"));
    let after = line.split(" in ").nth(1).unwrap_or_else(|| panic!("{func}: no case"));
    let words = after.split(')').next().unwrap();
    words.split('|').map(|w| w.trim().to_string()).collect()
}

/// The `"$R/path"` strings of `_owned_root`, without the `$R` prefix.
fn owned_paths(text: &str) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let mut inside = false;
    for l in text.lines() {
        if l.starts_with("_owned_root() {") {
            inside = true;
            continue;
        }
        if inside && l == "}" {
            break;
        }
        if inside {
            for (i, part) in l.split('"').enumerate() {
                if let (1, Some(path)) = (i % 2, part.strip_prefix("$R/")) {
                    out.insert(format!("/{path}"));
                }
            }
        }
    }
    out
}

fn table_words(p: verbs::Platform, verb: &str) -> BTreeSet<String> {
    match verbs::table(p).iter().find(|v| v.name == verb).unwrap().args {
        verbs::Args::OneOf(w) => w.iter().map(|s| s.to_string()).collect(),
        ref other => panic!("{verb}: {other:?}"),
    }
}

#[test]
fn sub_verb_and_owned_lists_equal_the_root_ops_lists() {
    let deb = root_ops_text("deb/root-ops");
    let mac = root_ops_text("mac/root-ops");

    assert_eq!(case_words(&deb, "_dns_verb"), table_words(verbs::Platform::Deb, "dns"));
    assert_eq!(case_words(&mac, "_agent_verb"), table_words(verbs::Platform::Mac, "agent"));

    let want = |p| verbs::owned(p).iter().map(|s| s.to_string()).collect::<BTreeSet<_>>();
    let deb_owned = owned_paths(&deb);
    assert_eq!(deb_owned.len(), 9, "scraped {deb_owned:?}");
    assert_eq!(deb_owned, want(verbs::Platform::Deb));
    let mac_owned = owned_paths(&mac);
    assert_eq!(mac_owned.len(), 5, "scraped {mac_owned:?}");
    assert_eq!(mac_owned, want(verbs::Platform::Mac));
}
