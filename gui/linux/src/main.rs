//! nice-dns-gui: the GTK4/libadwaita desktop GUI for nice-dns on Linux. It
//! reads only the `nice-dns` command contract (docs/cli-contract.md).

// The window (Task 1.2) and the buttons (Task 1.3) use the rest of these.
#![allow(dead_code)]

mod actions;
mod model;
mod runner;

use std::process::Command;

use glib::ExitCode;
use gtk4::prelude::*;
use libadwaita as adw;

use model::View;

const USAGE: &str = "usage: nice-dns-gui [--check | --version]";

/// The status command's argv: `<installed nice-dns> status --tsv`.
///
/// `NICE_DNS_GUI_STATUS_CMD`, when set, replaces it, split on whitespace. It
/// exists for tests and proofs only (a fake status script), not for users.
fn status_argv() -> Result<Vec<String>, runner::NotFound> {
    if let Some(cmd) = std::env::var_os("NICE_DNS_GUI_STATUS_CMD") {
        return Ok(cmd.to_string_lossy().split_whitespace().map(str::to_string).collect());
    }
    let bin = runner::resolve_installed("nice-dns")?;
    Ok(vec![bin.to_string_lossy().into_owned(), "status".into(), "--tsv".into()])
}

/// Run the status command once; the exit code and the one line `--check`
/// prints.
fn check(argv: &[String]) -> (i32, String) {
    let Some((program, args)) = argv.split_first() else {
        return (2, "nice-dns-gui: the status command is empty".into());
    };
    let out = match Command::new(program).args(args).output() {
        Ok(o) => o,
        Err(e) => return (2, format!("nice-dns-gui: cannot run {program}: {e}")),
    };
    let stdout = String::from_utf8_lossy(&out.stdout);
    match model::classify(out.status.code(), &stdout) {
        View::Installed(s) => {
            let unknown = || "unknown".to_string();
            let stale = s.controller.stale.map_or_else(unknown, |st| st.to_string());
            (
                0,
                format!(
                    "installed: generation {}; controller {}, {}",
                    s.install.generation.unwrap_or_else(unknown),
                    s.controller.verdict.unwrap_or_else(unknown),
                    stale
                ),
            )
        }
        View::NotInstalled(hint) => (
            1,
            match hint {
                Some(h) => format!("not installed; install with: {h}"),
                None => "not installed".into(),
            },
        ),
        View::Unreadable(s) => {
            let rows: Vec<String> =
                s.unreadable.iter().map(|u| format!("{}: {}", u.group, u.reason)).collect();
            (2, format!("unreadable: {}", rows.join("; ")))
        }
        View::Error(msg) => {
            let stderr = String::from_utf8_lossy(&out.stderr);
            match stderr.lines().find(|l| !l.trim().is_empty()) {
                Some(l) => (2, format!("error: {msg} ({})", l.trim())),
                None => (2, format!("error: {msg}")),
            }
        }
    }
}

fn run_check() -> i32 {
    let (code, line) = match status_argv() {
        Ok(argv) => check(&argv),
        Err(nf) => (1, format!("nice-dns command not found: looked for {}", nf.primary.display())),
    };
    println!("{line}");
    code
}

/// For now a bare window; Task 1.2 replaces it.
fn run_window() -> ExitCode {
    let app = adw::Application::builder().application_id("org.nice-dns.gui").build();
    app.connect_activate(|app| {
        adw::ApplicationWindow::builder()
            .application(app)
            .title("nice-dns")
            .default_width(480)
            .default_height(360)
            .build()
            .present();
    });
    // GTK is given no arguments: ours were parsed above.
    app.run_with_args::<&str>(&[])
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        [] => run_window(),
        ["--version"] => {
            println!("nice-dns-gui {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        ["--check"] => ExitCode::from(run_check()),
        _ => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake(fixture: &str, exit: i32) -> Vec<String> {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../share/fixtures");
        let fx = if fixture == "-" { "-".to_string() } else { format!("{dir}/{fixture}") };
        vec![format!("{dir}/fake-status.sh"), fx, exit.to_string()]
    }

    #[test]
    fn contract_check_installed_exits_0_naming_generation_verdict_and_staleness() {
        let (code, line) = check(&fake("status-installed.tsv", 0));
        assert_eq!(code, 0);
        assert_eq!(line, "installed: generation 20261109T180318Z-nogit0000000; controller OK, fresh");
        let (code, line) = check(&fake("status-stale.tsv", 0));
        assert_eq!(code, 0);
        assert!(line.ends_with("controller OK, stale 942s"), "{line}");
    }

    #[test]
    fn contract_check_not_installed_exits_1_with_the_hint() {
        let (code, line) = check(&fake("status-not-installed.tsv", 1));
        assert_eq!(code, 1);
        assert!(line.starts_with("not installed; install with: curl -fsSL "), "{line}");
    }

    #[test]
    fn contract_check_failures_exit_2() {
        assert_eq!(check(&fake("-", 2)).0, 2);
        assert_eq!(check(&fake("status-installed.tsv", 5)).0, 2);
        assert_eq!(check(&["/nonexistent/nice-dns".to_string()]).0, 2);
        assert_eq!(check(&[]).0, 2);
    }

    #[test]
    fn contract_check_unreadable_and_refused_schema_exit_2() {
        let installed = include_str!("../../share/fixtures/status-installed.tsv");
        let dir = std::env::temp_dir().join(format!("nice-dns-gui-check-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let unreadable = dir.join("unreadable.tsv");
        std::fs::write(
            &unreadable,
            installed.replacen("bridges\tcount\t7\n", "bridges\tunreadable\t~/x: permission denied\n", 1),
        )
        .unwrap();
        let wrong = dir.join("wrong.tsv");
        std::fs::write(&wrong, installed.replacen(model::SCHEMA, "nice-dns-status/2", 1)).unwrap();

        let mut argv = fake("-", 2);
        argv[1] = unreadable.to_string_lossy().into_owned();
        assert_eq!(check(&argv), (2, "unreadable: bridges: ~/x: permission denied".into()));
        argv[1] = wrong.to_string_lossy().into_owned();
        argv[2] = "0".into();
        let (code, line) = check(&argv);
        assert_eq!(code, 2);
        assert!(line.contains("nice-dns-status/2"), "{line}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
