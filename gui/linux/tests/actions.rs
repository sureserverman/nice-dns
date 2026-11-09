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
