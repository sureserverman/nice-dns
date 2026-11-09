//! `--run-action <id> --exit` under Xvfb against the fake commands in
//! gui/share/fixtures/fakebin. HOME is a scratch directory and PATH holds only
//! the fakes and the system directories, so no test can reach a real
//! `nice-dns`. Needs `xvfb-run`; without it the tests fail.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn fakebin() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../share/fixtures/fakebin")
}

struct Run {
    out: Output,
    record: String,
}

impl Run {
    fn stdout(&self) -> String {
        String::from_utf8_lossy(&self.out.stdout).into_owned()
    }
    fn code(&self) -> Option<i32> {
        self.out.status.code()
    }
}

fn run_action(id: &str, fake_exit: i32) -> Run {
    let home = std::env::temp_dir().join(format!("nice-dns-gui-actions-{}-{id}-{fake_exit}", std::process::id()));
    std::fs::create_dir_all(&home).unwrap();
    let record = home.join("record");
    let _ = std::fs::remove_file(&record);
    let out = Command::new("xvfb-run")
        .args(["-a", env!("CARGO_BIN_EXE_nice-dns-gui"), "--run-action", id, "--exit"])
        .env("PATH", format!("{}:/usr/bin:/bin", fakebin().display()))
        .env("HOME", &home)
        .env("XDG_STATE_HOME", home.join("state"))
        .env_remove("NICE_DNS_GUI_STATUS_CMD")
        .env("NICE_DNS_FAKE_RECORD", &record)
        .env("NICE_DNS_FAKE_EXIT", fake_exit.to_string())
        .env("GSK_RENDERER", "cairo")
        .output()
        .expect("xvfb-run is not installed (apt-get install xvfb)");
    let record = std::fs::read_to_string(&record).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&home);
    Run { out, record }
}

#[test]
fn actions_restart_runs_the_fake_and_its_lines_reach_the_pane_in_order() {
    let r = run_action("restart", 0);
    let out = r.stdout();
    assert_eq!(r.code(), Some(0), "{out}\n{}", String::from_utf8_lossy(&r.out.stderr));
    // The status read and the action, nothing else.
    assert_eq!(r.record, "status --tsv\nrestart\n");
    let first = out.find("fake nice-dns: restart").expect(&out);
    let last = out.find("fake nice-dns: done").expect(&out);
    assert!(first < last, "{out}");
    assert!(out.contains("fake nice-dns: a line on stderr"), "{out}");
    assert!(out.trim_end().ends_with("finished (exit 0)"), "{out}");
}

#[test]
fn actions_a_dismissed_dialog_shows_authorisation_cancelled() {
    let r = run_action("restart", 126);
    let out = r.stdout();
    assert_eq!(r.code(), Some(126), "{out}");
    assert!(out.trim_end().ends_with("authorisation cancelled (exit 126)"), "{out}");
}

#[test]
fn actions_a_failure_keeps_its_output_and_exit_code() {
    let r = run_action("update", 3);
    let out = r.stdout();
    assert_eq!(r.code(), Some(3), "{out}");
    assert!(out.contains("fake nice-dns: update"), "{out}");
    assert!(out.trim_end().ends_with("failed (exit 3)"), "{out}");
}

#[test]
fn actions_bridges_off_and_the_controller_run_their_exact_commands() {
    let r = run_action("bridges-off", 0);
    assert_eq!(r.code(), Some(0), "{}", r.stdout());
    assert_eq!(r.record, "status --tsv\nbridges off\n");
    let r = run_action("health-run", 0);
    assert_eq!(r.code(), Some(0), "{}", r.stdout());
    assert!(r.stdout().contains("fake nice-dns-health: run"), "{}", r.stdout());
    let r = run_action("update-check", 10);
    assert_eq!(r.code(), Some(10));
    assert!(r.stdout().trim_end().ends_with("an update is available (exit 10)"), "{}", r.stdout());
}

#[test]
fn actions_an_action_that_runs_nothing_is_refused_as_a_hook() {
    let r = run_action("open-admin", 0);
    assert_eq!(r.code(), Some(2));
    assert!(r.record.is_empty());
}

// ─────────── the window's own behaviour, through --probe ───────────

struct Probe {
    code: Option<i32>,
    out: String,
    record: String,
}

impl Probe {
    /// The report line starting `<when>:`.
    fn at(&self, when: &str) -> &str {
        let p = format!("{when}:");
        self.out.lines().find(|l| l.starts_with(&p)).unwrap_or_else(|| panic!("no {when} line in:\n{}", self.out))
    }
}

/// `--probe <id>` under Xvfb with the fakes; `status_fixture` (a file in
/// fixtures) replaces the fake's status when given; `with_fakes` false leaves
/// no nice-dns anywhere.
fn probe(id: &str, fake_exit: i32, status_fixture: Option<&str>, with_fakes: bool) -> Probe {
    let home = std::env::temp_dir().join(format!("nice-dns-gui-probe-{}-{id}-{fake_exit}", std::process::id()));
    std::fs::create_dir_all(&home).unwrap();
    let record = home.join("record");
    let _ = std::fs::remove_file(&record);
    let path = if with_fakes { format!("{}:/usr/bin:/bin", fakebin().display()) } else { "/usr/bin:/bin".into() };
    let mut cmd = Command::new("xvfb-run");
    cmd.args(["-a", env!("CARGO_BIN_EXE_nice-dns-gui"), "--probe", id])
        .env("PATH", path)
        .env("HOME", &home)
        .env("XDG_STATE_HOME", home.join("state"))
        .env_remove("NICE_DNS_GUI_STATUS_CMD")
        .env("NICE_DNS_FAKE_RECORD", &record)
        .env("NICE_DNS_FAKE_EXIT", fake_exit.to_string())
        .env("GSK_RENDERER", "cairo");
    if let Some(f) = status_fixture {
        let fx = fakebin().join("..");
        cmd.env("NICE_DNS_GUI_STATUS_CMD", format!("{} {} 0", fx.join("fake-status.sh").display(), fx.join(f).display()));
    }
    let out = cmd.output().expect("xvfb-run is not installed (apt-get install xvfb)");
    let record = std::fs::read_to_string(&record).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&home);
    Probe {
        code: out.status.code(),
        out: format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr)),
        record,
    }
}

fn field<'a>(line: &'a str, key: &str) -> &'a str {
    let p = format!("{key}=");
    line.split(' ').find_map(|w| w.strip_prefix(&p)).unwrap_or_else(|| panic!("no {key} in {line}"))
}

#[test]
fn actions_one_at_a_time_the_controls_are_disabled_while_it_runs_and_back_after_a_failure() {
    let p = probe("restart", 3, None, true);
    assert_eq!(p.code, Some(0), "{}", p.out);
    let controls: u32 = field(p.at("before"), "controls").parse().unwrap();
    assert!(controls >= 10, "{}", p.out);
    assert_eq!(field(p.at("before"), "disabled"), "0", "{}", p.out);
    assert_eq!(field(p.at("during"), "disabled"), controls.to_string(), "every control is disabled while it runs: {}", p.out);
    assert_eq!(field(p.at("after"), "disabled"), "0", "the controls come back after a failure: {}", p.out);
    // The second click while it ran (Uninstall) opened no dialog and started nothing.
    assert_eq!(field(p.at("second"), "dialog"), "none", "{}", p.out);
    assert_eq!(p.record, "status --tsv\nrestart\nstatus --tsv\n", "{}", p.out);
    assert!(p.out.contains("close-while-busy: refused"), "{}", p.out);
    assert!(p.out.contains("pane: failed (exit 3)"), "{}", p.out);
}

#[test]
fn actions_the_bridges_switch_runs_its_command_and_shows_the_status_mode_after_a_failure() {
    let p = probe("bridges-off", 3, None, true);
    assert_eq!(p.code, Some(0), "{}", p.out);
    assert!(p.record.contains("bridges off"), "{}", p.record);
    // While it runs the switch shows what was asked for.
    assert_eq!(field(p.at("during"), "switch"), "off", "{}", p.out);
    // The command failed and the status still says on: the switch says on.
    assert_eq!(field(p.at("after"), "switch"), "on", "{}", p.out);
}

#[test]
fn actions_a_check_that_finds_an_update_offers_to_install_it() {
    let p = probe("update-check", 10, None, true);
    assert_eq!(p.code, Some(0), "{}", p.out);
    assert!(p.record.contains("update --check"), "{}", p.record);
    let after = p.at("after");
    assert_eq!(field(after, "dialog"), "Install_the_update?", "{}", p.out);
    // It names the commit this check printed.
    assert!(after.contains("0123456789ab"), "{after}");
    // Nothing was installed without an answer.
    assert!(!p.record.lines().any(|l| l == "update"), "{}", p.record);
}

#[test]
fn actions_a_stale_controller_shows_the_label_and_greys_its_rows() {
    let p = probe("health-run", 0, Some("status-stale.tsv"), true);
    assert_eq!(p.code, Some(0), "{}", p.out);
    let before = p.at("before");
    assert!(before.contains("stale=stale 942s"), "{before}");
    assert!(field(before, "greyed").parse::<u32>().unwrap() > 0, "{before}");
}

#[test]
fn actions_a_missing_command_is_one_error_page_naming_the_path() {
    let p = probe("restart", 0, None, false);
    assert_eq!(p.code, Some(0), "{}", p.out);
    let before = p.at("before");
    assert!(before.contains("page=error: The nice-dns command is not installed: looked for "), "{before}");
    assert!(before.contains("/.local/bin/nice-dns"), "{before}");
}

#[test]
fn contract_check_without_the_command_exits_1_naming_the_path() {
    let home = std::env::temp_dir().join(format!("nice-dns-gui-nocmd-{}", std::process::id()));
    std::fs::create_dir_all(&home).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_nice-dns-gui"))
        .arg("--check")
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", &home)
        .env("XDG_STATE_HOME", home.join("state"))
        .env_remove("NICE_DNS_GUI_STATUS_CMD")
        .output()
        .unwrap();
    let line = String::from_utf8_lossy(&out.stdout).into_owned();
    let _ = std::fs::remove_dir_all(&home);
    assert_eq!(out.status.code(), Some(1), "{line}");
    assert_eq!(line.trim(), format!("nice-dns command not found: looked for {}/.local/bin/nice-dns", home.display()));
}
