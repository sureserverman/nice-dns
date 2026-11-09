//! nice-dns-gui: the GTK4/libadwaita desktop GUI for nice-dns on Linux. It
//! reads only the `nice-dns` command contract (docs/cli-contract.md).


mod actions;
mod log_pane;
mod model;
mod runner;
mod window;

use std::cell::Cell;
use std::path::PathBuf;
use std::process::Command;
use std::rc::Rc;
use std::time::Duration;

use gtk4::{gio, glib};
use glib::ExitCode;
use gtk4::prelude::*;
use adw::prelude::*;
use libadwaita as adw;

use model::View;

const USAGE: &str =
    "usage: nice-dns-gui [--check | --version | --screenshot <png> | --run-action <id> --exit | --probe <id>]";

/// The status command's argv: `<nice-dns> status --tsv`, the command found
/// as `runner::resolve` finds it (PATH first, then where the installer put it).
///
/// `NICE_DNS_GUI_STATUS_CMD`, when set, replaces it, split on whitespace. It
/// exists for tests and proofs only (a fake status script), not for users.
pub(crate) fn status_argv() -> Result<Vec<String>, runner::NotFound> {
    if let Some(cmd) = std::env::var_os("NICE_DNS_GUI_STATUS_CMD") {
        return Ok(cmd.to_string_lossy().split_whitespace().map(str::to_string).collect());
    }
    let bin = runner::resolve("nice-dns")?;
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
        // Exit 2 with `installed no` is still "not installed", with exit 2 as
        // status gave it (the contract: 2 wins over 1).
        View::NotInstalled { hint, unreadable } => {
            let mut line = "not installed".to_string();
            if !unreadable.is_empty() {
                let rows: Vec<String> = unreadable.iter().map(|u| format!("{}: {}", u.group, u.reason)).collect();
                line = format!("{line}; unreadable: {}", rows.join("; "));
            }
            if let Some(h) = hint {
                line = format!("{line}; install with: {h}");
            }
            (if unreadable.is_empty() { 1 } else { 2 }, line)
        }
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

/// The application. The hooks run `unique = false`, so a window already open
/// in the session is never handed their work.
fn application(unique: bool) -> adw::Application {
    let flags = if unique { gio::ApplicationFlags::empty() } else { gio::ApplicationFlags::NON_UNIQUE };
    adw::Application::builder().application_id("org.nice_dns.Gui").flags(flags).build()
}

/// The window: the status, refreshed every few seconds.
fn run_window() -> ExitCode {
    if let Err(code) = display_or_exit() {
        return code;
    }
    let app = application(true);
    app.connect_activate(|app| {
        let ui = window::Ui::new(app);
        ui.start_refreshing();
        ui.window.present();
    });
    // GTK is given no arguments: ours were parsed above.
    app.run_with_args::<&str>(&[])
}

/// `--screenshot <png>`: read the status once, show the window, render it
/// into `png` and exit (0, or 1 with the reason on stderr). A hook for tests
/// and proofs; it needs a display (Xvfb will do).
fn run_screenshot(png: PathBuf) -> ExitCode {
    if let Err(code) = display_or_exit() {
        return code;
    }
    let app = application(false);
    let code = Rc::new(Cell::new(1i32));
    let c = Rc::clone(&code);
    app.connect_activate(move |app| {
        let ui = window::Ui::new(app);
        let (page, status) = window::read_page();
        ui.show(page, status);
        ui.window.present();
        let (app, c, png) = (app.clone(), Rc::clone(&c), png.clone());
        // Give the window a frame or two to lay out before rendering it.
        glib::timeout_add_local_once(Duration::from_millis(800), move || {
            match ui.save_png(&png) {
                Ok(()) => c.set(0),
                Err(e) => eprintln!("nice-dns-gui: screenshot: {e}"),
            }
            ui.window.close();
            app.quit();
        });
    });
    app.run_with_args::<&str>(&[]);
    ExitCode::from(code.get())
}

/// `--run-action <id> --exit`: show the window, run action `id` with no
/// dialog, print the log pane's text on stdout and exit with the action's
/// status. A hook for tests and proofs; it needs a display (Xvfb will do).
fn run_action(id: String) -> ExitCode {
    if actions::lookup(&id).and_then(|a| a.program).is_none() {
        eprintln!("nice-dns-gui: '{id}' is not an action that runs a command");
        return ExitCode::from(2);
    }
    if let Err(code) = display_or_exit() {
        return code;
    }
    let app = application(false);
    let code = Rc::new(Cell::new(1i32));
    let c = Rc::clone(&code);
    app.connect_activate(move |app| {
        let ui = window::Ui::new(app);
        let (page, status) = window::read_page();
        ui.show(page, status);
        ui.window.present();
        let (app, c, pane_ui) = (app.clone(), Rc::clone(&c), Rc::clone(&ui));
        ui.run_headless(
            &id,
            Rc::new(move |status| {
                print!("{}", pane_ui.pane.text());
                c.set(status);
                pane_ui.window.close();
                app.quit();
            }),
        );
    });
    app.run_with_args::<&str>(&[]);
    ExitCode::from(code.get().clamp(0, 255))
}

/// The window and the hooks need a display; without one GTK cannot start.
fn display_or_exit() -> Result<(), ExitCode> {
    gtk4::init().map_err(|e| {
        eprintln!("nice-dns-gui: no display: {e} (the window and the hooks need one; Xvfb will do)");
        ExitCode::from(2)
    })
}

/// Every widget under `w`, `w` first.
fn walk(w: &gtk4::Widget, f: &mut dyn FnMut(&gtk4::Widget)) {
    f(w);
    let mut child = w.first_child();
    while let Some(c) = child {
        walk(&c, f);
        child = c.next_sibling();
    }
}

/// What a test reads off the window: the controls (action buttons and the
/// bridges switch) and how many are disabled, the switch, the open dialog, the
/// stale labels and how many rows are greyed.
fn probe_report(ui: &window::Ui, when: &str) -> String {
    let (mut controls, mut disabled, mut greyed) = (0, 0, 0);
    let mut switch = "none".to_string();
    let mut stale = Vec::new();
    walk(ui.window.upcast_ref(), &mut |w| {
        let name = w.widget_name();
        if name == "bridges" || actions::lookup(&name).is_some() {
            controls += 1;
            if !w.is_sensitive() {
                disabled += 1;
            }
        }
        if let Some(sw) = w.downcast_ref::<adw::SwitchRow>() {
            switch = if sw.is_active() { "on" } else { "off" }.into();
        } else if w.is::<adw::ActionRow>() && !w.is_sensitive() {
            greyed += 1;
        }
        if let Some(l) = w.downcast_ref::<gtk4::Label>() {
            if l.has_css_class("warning") && l.text().starts_with("stale") {
                stale.push(l.text().to_string());
            }
        }
    });
    let dialog = ui
        .window
        .visible_dialog()
        .and_then(|d| d.downcast::<adw::AlertDialog>().ok())
        .and_then(|d| d.heading())
        .map_or("none".to_string(), |h| h.to_string());
    format!(
        "{when}: controls={controls} disabled={disabled} switch={switch} greyed={greyed} stale={} dialog={dialog} page={}",
        if stale.is_empty() { "none".into() } else { stale.join(",") },
        ui.page_summary()
    )
}

/// `--probe <id>`: a test hook for the window's own behaviour. It shows the
/// status, prints a report, clicks `id` the way a person would (the switch for
/// `bridges-on`/`bridges-off`, otherwise the action, dialogs included), prints
/// a report while it runs, clicks Restart again (one action at a time: that
/// second click must start nothing) and tries to close the window (refused
/// while an action runs), waits until the action has ended and the
/// status was read again, prints a last report with the pane's last line, and
/// exits 0 (3 when it never settles within 60 s). It needs a display.
fn run_probe(id: String) -> ExitCode {
    if let Err(code) = display_or_exit() {
        return code;
    }
    let app = application(false);
    let code = Rc::new(Cell::new(1i32));
    let c = Rc::clone(&code);
    app.connect_activate(move |app| {
        let ui = window::Ui::new(app);
        let (page, status) = window::read_page();
        ui.show(page, status);
        ui.window.present();
        let (app, c, id) = (app.clone(), Rc::clone(&c), id.clone());
        glib::timeout_add_local_once(Duration::from_millis(500), move || {
            println!("{}", probe_report(&ui, "before"));
            if id == "bridges-on" || id == "bridges-off" {
                walk(ui.window.upcast_ref(), &mut |w| {
                    if let Some(sw) = w.downcast_ref::<adw::SwitchRow>() {
                        sw.set_active(id == "bridges-on");
                    }
                });
            } else {
                ui.act(&id);
            }
            println!("{}", probe_report(&ui, "during"));
            if ui.is_busy() {
                ui.act("restart");
                // Closing while it runs is refused.
                ui.window.close();
                println!("close-while-busy: {}", if ui.window.is_visible() { "refused" } else { "closed" });
            }
            let started = std::time::Instant::now();
            glib::timeout_add_local(Duration::from_millis(100), move || {
                if !ui.settled() && started.elapsed() < Duration::from_secs(60) {
                    return glib::ControlFlow::Continue;
                }
                if ui.settled() {
                    println!("{}", probe_report(&ui, "after"));
                    println!("pane: {}", ui.pane.text().lines().last().unwrap_or(""));
                    c.set(0);
                } else {
                    eprintln!("nice-dns-gui: the window did not settle within 60 s");
                    c.set(3);
                }
                if let Some(d) = ui.window.visible_dialog() {
                    d.force_close();
                }
                ui.window.destroy();
                app.quit();
                glib::ControlFlow::Break
            });
        });
    });
    app.run_with_args::<&str>(&[]);
    ExitCode::from(code.get())
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
        ["--screenshot", png] => run_screenshot(PathBuf::from(png)),
        ["--run-action", id, "--exit"] => run_action(id.to_string()),
        ["--probe", id] if actions::lookup(id).is_some() => run_probe(id.to_string()),
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
    fn contract_check_not_installed_with_an_unreadable_file_exits_2_and_says_not_installed() {
        let dir = std::env::temp_dir().join(format!("nice-dns-gui-check-ni-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("ni-unreadable.tsv");
        let text = include_str!("../../share/fixtures/status-not-installed.tsv");
        std::fs::write(&f, format!("{text}bridges\tunreadable\t~/x: permission denied\n")).unwrap();
        let mut argv = fake("-", 2);
        argv[1] = f.to_string_lossy().into_owned();
        let (code, line) = check(&argv);
        assert_eq!(code, 2);
        assert!(line.starts_with("not installed; unreadable: bridges: ~/x: permission denied; install with: curl "), "{line}");
        let _ = std::fs::remove_dir_all(&dir);
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
