//! The status window (Task 1.2). `describe` turns what `nice-dns status --tsv`
//! said into a page description with no GTK in it, so the tests check it with
//! no display; `Ui` builds the widgets from that description and refreshes it
//! every 5 s. The window reports what the command says and never changes the
//! install itself (DEC-018): every change is an action the person starts.

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::rc::Rc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use adw::prelude::*;
use gtk4 as gtk;
use gtk::{gio, glib};
use libadwaita as adw;

use crate::actions::{self, Choices};
use crate::log_pane::{self, LogPane};
use crate::model::{self, Moment, Stale, Status, UpdateResult, View};
use crate::runner::{self, Event, Exit, Stream};

/// How often the window reads `nice-dns status --tsv` again.
pub const REFRESH: Duration = Duration::from_secs(5);

/// How many output lines the pane takes per 50 ms tick.
const LINES_PER_TICK: usize = 200;

// ---------------------------------------------------------------- description

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Page {
    /// The rows were read (with or without `unreadable` groups).
    Installed(Body),
    /// `install installed no`; Install is offered only when the kept source
    /// exists, since `nice-dns install` runs from it. `unreadable`: the files
    /// `status` could not read (exit 2), one line each.
    NotInstalled { hint: Option<String>, can_install: bool, unreadable: Vec<String> },
    /// The command is missing, failed, or said something the contract does not.
    Error(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Body {
    /// The header's subtitle: what is installed.
    pub subtitle: String,
    /// The update banner's text when the last check found a different commit.
    pub update_available: Option<String>,
    /// One line per `<group> unreadable <reason>` row.
    pub unreadable: Vec<String>,
    pub sections: Vec<Section>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Section {
    pub id: &'static str,
    pub title: &'static str,
    /// Shown under the title, e.g. `stale 942s`.
    pub note: Option<String>,
    /// The controller's view is old: the rows are dimmed.
    pub greyed: bool,
    pub rows: Vec<Row>,
    /// Action ids (gui/share/actions.tsv) offered as buttons under the rows.
    pub buttons: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub title: String,
    pub subtitle: String,
    pub kind: RowKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RowKind {
    Text,
    /// A verdict shown as a coloured word at the end of the row.
    Verdict(String),
    /// The bridges switch: on or off.
    BridgesSwitch(bool),
    /// The Proxy or Pi-hole selector.
    Selector(Selector),
}

/// A two-choice selector whose picks are rows of the action table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Selector {
    /// `proxy` or `pihole`: the widget is named `selector-<kind>`.
    pub kind: &'static str,
    /// What the question calls it: "Switch {subject} to {choice}?".
    pub subject: &'static str,
    pub choices: [&'static str; 2],
    /// The action ids (gui/share/actions.tsv) that pick each choice.
    pub actions: [&'static str; 2],
    /// Which choice `status` names; `None`: it names none, or one outside the
    /// two, and the selector is disabled and says `unknown`.
    pub installed: Option<usize>,
}

const PROXY: Selector = Selector {
    kind: "proxy",
    subject: "the proxy",
    choices: ["haproxy", "socat"],
    actions: ["proxy-haproxy", "proxy-socat"],
    installed: None,
};
const PIHOLE: Selector = Selector {
    kind: "pihole",
    subject: "Pi-hole",
    choices: ["standard", "hardened"],
    actions: ["pihole-standard", "pihole-hardened"],
    installed: None,
};

/// The bridges switch's two actions: on, off.
const BRIDGES_ACTIONS: [&str; 2] = ["bridges-on", "bridges-off"];
/// What the update banner's button runs (after asking).
const BANNER_ACTION: &str = "update";
/// What the not-installed page's button runs.
const INSTALL_ACTION: &str = "install";

fn selector(base: Selector, value: &Option<String>) -> Selector {
    let installed = value.as_deref().and_then(|v| base.choices.iter().position(|c| *c == v));
    Selector { installed, ..base }
}

/// The selector and the choice index that action `id` picks, if it is one of
/// the four selector actions.
pub fn selector_for(id: &str) -> Option<(Selector, usize)> {
    [PROXY, PIHOLE].into_iter().find_map(|s| s.actions.iter().position(|a| *a == id).map(|i| (s, i)))
}

fn row(title: impl Into<String>, subtitle: impl Into<String>) -> Row {
    Row { title: title.into(), subtitle: subtitle.into(), kind: RowKind::Text }
}

/// `epoch` said as a time before `now`: "just now", "5 min ago", "3 h ago".
pub fn ago(epoch: u64, now: u64) -> String {
    if epoch > now {
        return "in the future".into();
    }
    match now - epoch {
        s if s < 60 => "just now".into(),
        s if s < 3600 => format!("{} min ago", s / 60),
        s if s < 86_400 => format!("{} h ago", s / 3600),
        s => format!("{} days ago", s / 86_400),
    }
}

fn moment(m: Option<Moment>, now: u64) -> String {
    match m {
        Some(Moment::At(e)) => ago(e, now),
        Some(Moment::Never) => "never".into(),
        None => "unknown".into(),
    }
}

fn or_unknown(v: &Option<String>) -> String {
    v.clone().unwrap_or_else(|| "unknown".into())
}

fn short(sha: &str) -> &str {
    sha.get(..12).unwrap_or(sha)
}

/// The page for what `status` said. `now` is the epoch the times are said
/// against; `can_install` whether the kept source exists.
pub fn describe(view: &View, now: u64, can_install: bool) -> Page {
    match view {
        View::Installed(s) | View::Unreadable(s) => Page::Installed(body(s, now)),
        View::NotInstalled { hint, unreadable } => Page::NotInstalled {
            hint: hint.clone(),
            can_install,
            unreadable: unreadable.iter().map(|u| format!("{}: {}", u.group, u.reason)).collect(),
        },
        View::Error(msg) => Page::Error(format!("nice-dns status did not answer as expected: {msg}")),
    }
}

fn body(s: &Status, now: u64) -> Body {
    let i = &s.install;
    let mut sub = vec![format!("generation {}", or_unknown(&i.generation))];
    if let Some(v) = &i.variant {
        sub.push(v.clone());
    }
    if let Some(p) = &i.pihole {
        sub.push(format!("{p} Pi-hole"));
    }
    if let Some(b) = &i.branch {
        sub.push(format!("branch {b}"));
    }

    let update_available = match s.update.result {
        Some(UpdateResult::Available) => Some(match &s.update.remote_commit {
            Some(c) => format!("A different version is available: {}", short(c)),
            None => "A different version is available".into(),
        }),
        _ => None,
    };
    let update_line = match (s.update.result, s.update.never_checked) {
        (_, true) => "not checked yet".to_string(),
        (Some(UpdateResult::Current), _) => "up to date".into(),
        (Some(UpdateResult::Available), _) => match &s.update.remote_commit {
            Some(c) => format!("available: {}", short(c)),
            None => "available".into(),
        },
        _ => "unknown".into(),
    };
    let checked = s.update.checked_at.map(|t| format!(" (checked {})", ago(t, now))).unwrap_or_default();

    let stale = s.controller.stale.filter(|st| *st != Stale::No);
    let stale_note = stale.map(|st| st.to_string());
    let greyed = stale.is_some();

    let mut installed = vec![
        row("Generation", or_unknown(&i.generation)),
        row("Source commit", i.source_commit.as_deref().map(short).unwrap_or("unknown")),
        Row { title: "Proxy".into(), subtitle: String::new(), kind: RowKind::Selector(selector(PROXY, &i.variant)) },
        Row { title: "Pi-hole".into(), subtitle: String::new(), kind: RowKind::Selector(selector(PIHOLE, &i.pihole)) },
        row("Update", format!("{update_line}{checked}")),
    ];
    installed.push(row(
        "Helper",
        match (s.helper.installed, &s.helper.version) {
            (Some(true), Some(v)) => format!("installed, {v}"),
            (Some(true), None) => "installed".into(),
            (Some(false), _) => "not installed: actions that need root will ask in a terminal".into(),
            (None, _) => "unknown".into(),
        },
    ));

    let verdict_row = |o: &model::Obs, title: String| Row {
        title,
        subtitle: o.reason.clone(),
        kind: RowKind::Verdict(o.verdict.clone()),
    };
    let mut containers: Vec<Row> = s
        .obs
        .iter()
        .filter_map(|o| o.name.strip_prefix("container:").map(|n| verdict_row(o, n.to_string())))
        .collect();
    let mut observations: Vec<Row> =
        s.obs.iter().filter(|o| !o.name.starts_with("container:")).map(|o| verdict_row(o, o.name.clone())).collect();
    if containers.is_empty() {
        containers.push(row("No observations yet", "the controller has recorded no pass"));
    }
    if observations.is_empty() {
        observations.push(row("No observations yet", "the controller has recorded no pass"));
    }

    let on = s.bridges.mode.as_deref() != Some("off");
    let bridges_sub = format!(
        "{} bridges, last refresh {}",
        s.bridges.count.map_or_else(|| "unknown".into(), |c| c.to_string()),
        moment(s.bridges.last_refresh, now)
    );
    let bridges_note = (!on).then(|| "Tor runs without bridges: your ISP can see that Tor is in use".to_string());

    let c = &s.controller;
    let mut controller = vec![
        row("Verdict", or_unknown(&c.verdict)),
        row("Last pass", moment(c.last_pass, now)),
        row("Mode", or_unknown(&c.mode)),
        row("Schedule", or_unknown(&c.schedule)),
    ];
    if let Some(r) = &s.route {
        controller.push(row("Route", r.id.clone()));
    }

    let mut recent: Vec<Row> = s
        .recent
        .iter()
        .rev()
        .map(|r| row(r.target.clone(), format!("{}, {}", r.result, r.epoch.map_or_else(|| "unknown".into(), |e| ago(e, now)))))
        .collect();
    if recent.is_empty() {
        recent.push(row("Nothing yet", "the controller's journal is empty"));
    }

    let admin = vec![
        row("Admin page", or_unknown(&s.admin.url)),
        row("Password file", s.admin.password_path.clone().unwrap_or_else(|| "not recorded".into())),
    ];

    let section = |id, title, note: Option<String>, greyed, rows, buttons| Section { id, title, note, greyed, rows, buttons };
    Body {
        subtitle: sub.join(" · "),
        update_available,
        unreadable: s.unreadable.iter().map(|u| format!("{}: {}", u.group, u.reason)).collect(),
        sections: vec![
            section("containers", "Containers", stale_note.clone(), greyed, containers, vec![]),
            section("bridges", "Bridges", bridges_note, false, vec![Row {
                title: "Use Tor bridges".into(),
                subtitle: bridges_sub,
                kind: RowKind::BridgesSwitch(on),
            }], vec![]),
            section(
                "controller",
                "Health controller",
                stale_note.clone(),
                greyed,
                controller,
                vec!["health-run", "health-start", "health-stop", "failures"],
            ),
            section("installed", "Installed", None, false, installed, vec!["update-check", "restart", "reinstall", "uninstall"]),
            section("admin", "Pi-hole admin", None, false, admin, vec!["open-admin", "show-password-path"]),
            section("recent", "Recent actions", None, false, recent, vec![]),
            section("observations", "Observations", stale_note, greyed, observations, vec![]),
        ],
    }
}

// ------------------------------------------------------------------- reading

/// Whether `nice-dns install` has the source it runs from.
fn source_kept() -> bool {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join(".local/share/nice-dns/source/lib/install.sh").is_file()
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

/// Run the status command once and describe what it said. Blocking: call it
/// off the main loop.
pub fn read_page() -> (Page, Option<Status>) {
    let argv = match crate::status_argv() {
        Ok(a) => a,
        Err(nf) => {
            return (
                Page::Error(format!("The nice-dns command is not installed: looked for {}", nf.primary.display())),
                None,
            )
        }
    };
    let Some((program, args)) = argv.split_first() else {
        return (Page::Error("the status command is empty".into()), None);
    };
    match Command::new(program).args(args).output() {
        Ok(o) => {
            let mut view = model::classify(o.status.code(), &String::from_utf8_lossy(&o.stdout));
            // The command's own reason (say, a kept source older than
            // `status`) is on stderr: show its first line with the error.
            if let View::Error(msg) = &view {
                let stderr = String::from_utf8_lossy(&o.stderr);
                if let Some(l) = stderr.lines().map(str::trim).find(|l| !l.is_empty()) {
                    view = View::Error(format!("{msg}: {l}"));
                }
            }
            let status = match &view {
                View::Installed(s) | View::Unreadable(s) => Some(s.clone()),
                _ => None,
            };
            (describe(&view, now(), source_kept()), status)
        }
        Err(e) => (Page::Error(format!("cannot run {program}: {e}")), None),
    }
}

// ------------------------------------------------------------------- widgets

/// Called with the action's exit status when `--run-action` ran it.
pub type OnDone = Rc<dyn Fn(i32)>;

pub struct Ui {
    pub window: adw::ApplicationWindow,
    title: adw::WindowTitle,
    banner: adw::Banner,
    toasts: adw::ToastOverlay,
    scroller: gtk::ScrolledWindow,
    /// The running or last action's output.
    pub pane: LogPane,
    shown: RefCell<Option<Page>>,
    pub status: RefCell<Option<Status>>,
    reading: Cell<bool>,
    /// Bumped when an action ends: a read that began before it is dropped.
    read_gen: Cell<u64>,
    /// An action is running: buttons and the switch are disabled, one action
    /// at a time.
    busy: Cell<bool>,
    /// Set by `--run-action`: no dialogs, and this is told the exit status.
    headless: RefCell<Option<OnDone>>,
    /// When a close was refused while an action ran.
    close_asked: Cell<Option<std::time::Instant>>,
    /// The bridges mode a running bridges-on/off asked for: the switch shows
    /// it until the status says what came of it.
    bridges_pending: Cell<Option<bool>>,
    /// The selector pick a running switch asked for (selector kind, choice
    /// index): the selector shows it until the status says what came of it.
    selector_pending: Cell<Option<(&'static str, usize)>>,
    /// The last toast's text (the probe hook reports it).
    last_toast: RefCell<String>,
}

impl Ui {
    pub fn new(app: &adw::Application) -> Rc<Ui> {
        let title = adw::WindowTitle::new("nice-dns", "");
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&title));

        let banner = adw::Banner::new("");
        banner.set_button_label(Some("Apply"));

        let scroller = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).build();
        let pane = LogPane::new();
        let column = gtk::Box::new(gtk::Orientation::Vertical, 0);
        column.append(&banner);
        column.append(&scroller);
        column.append(&pane.widget);

        let toasts = adw::ToastOverlay::new();
        toasts.set_child(Some(&column));
        let view = adw::ToolbarView::new();
        view.add_top_bar(&header);
        view.set_content(Some(&toasts));

        let window = adw::ApplicationWindow::builder()
            .application(app)
            .title("nice-dns")
            .icon_name("nice-dns")
            .default_width(720)
            .default_height(900)
            .content(&view)
            .build();

        let ui = Rc::new(Ui {
            window,
            title,
            banner,
            toasts,
            scroller,
            pane,
            shown: RefCell::new(None),
            status: RefCell::new(None),
            reading: Cell::new(false),
            read_gen: Cell::new(0),
            busy: Cell::new(false),
            headless: RefCell::new(None),
            close_asked: Cell::new(None),
            bridges_pending: Cell::new(None),
            selector_pending: Cell::new(None),
            last_toast: RefCell::new(String::new()),
        });
        let weak = Rc::downgrade(&ui);
        ui.banner.connect_button_clicked(move |_| {
            if let Some(ui) = weak.upgrade() {
                ui.act(BANNER_ACTION);
            }
        });
        // Closing the window would end this process and leave the running
        // command with no one reading its output, midway through (say) a
        // reinstall: the window stays until the action ends.
        let weak = Rc::downgrade(&ui);
        // A command that hangs (a dialog nobody answers) must not trap the
        // person: a second close within 10 s goes through.
        ui.window.connect_close_request(move |_| match weak.upgrade() {
            Some(ui) if ui.busy.get() => {
                let now = std::time::Instant::now();
                if ui.close_asked.get().is_some_and(|t| now.duration_since(t) < Duration::from_secs(10)) {
                    return glib::Propagation::Proceed;
                }
                ui.close_asked.set(Some(now));
                ui.toast("An action is running; close again to leave it running without this window");
                glib::Propagation::Stop
            }
            _ => glib::Propagation::Proceed,
        });
        ui
    }

    /// The page shown, in one line: `installed`, `not-installed` or
    /// `error: <message>`.
    pub fn page_summary(&self) -> String {
        match self.shown.borrow().as_ref() {
            Some(Page::Installed(_)) => "installed".into(),
            Some(Page::NotInstalled { .. }) => "not-installed".into(),
            Some(Page::Error(m)) => format!("error: {m}"),
            None => "none".into(),
        }
    }

    /// Whether an action is running.
    pub fn is_busy(&self) -> bool {
        self.busy.get()
    }

    /// No action running, no read under way, and a page shown: what a test
    /// may inspect.
    pub fn settled(&self) -> bool {
        !self.busy.get() && !self.reading.get() && self.shown.borrow().is_some()
    }

    /// A button, the switch or the banner asked for action `id`. Actions
    /// that change the install ask first; the rest run at once.
    pub fn act(self: &Rc<Self>, id: &str) {
        if matches!(id, "open-admin" | "show-password-path") {
            return self.act_local(id);
        }
        if self.busy.get() {
            return self.toast("Another action is running");
        }
        if let Some((sel, idx)) = selector_for(id) {
            return self.ask_switch(sel, idx, None);
        }
        match id {
            "uninstall" => self.confirm_uninstall(),
            "reinstall" => self.choose_reinstall(),
            "update" => self.confirm_update(None),
            _ => self.run(id, None),
        }
    }

    /// `--run-action`: run `id` with no dialog (reinstall keeps the recorded
    /// choices) and call `done` with its exit status.
    pub fn run_headless(self: &Rc<Self>, id: &str, done: OnDone) {
        *self.headless.borrow_mut() = Some(done);
        self.run(id, None);
    }

    /// Run action `id` now, streaming its output into the pane.
    pub fn run(self: &Rc<Self>, id: &str, choices: Option<&Choices>) {
        // Every way in (a button, a dialog's answer, the hook) meets this:
        // one action at a time.
        if self.busy.get() {
            return self.toast("Another action is running");
        }
        let label = actions::lookup(id).map_or(id, |a| a.label).to_string();
        let argv = match actions::argv(id, choices, runner::resolve) {
            Ok(Some(v)) => v,
            Ok(None) => return self.act_local(id),
            Err(e) => {
                self.pane.start(&label, &[]);
                return self.end(id, Event::Failed(e));
            }
        };
        match id {
            "bridges-on" => self.bridges_pending.set(Some(true)),
            "bridges-off" => self.bridges_pending.set(Some(false)),
            _ => {}
        }
        if let Some((sel, idx)) = selector_for(id) {
            self.selector_pending.set(Some((sel.kind, idx)));
        }
        self.set_busy(true);
        self.pane.start(&label, &argv);
        let rx = match runner::spawn(&argv) {
            Ok(rx) => rx,
            Err(e) => return self.end(id, Event::Failed(e.to_string())),
        };
        let (ui, id) = (Rc::clone(self), id.to_string());
        // At most LINES_PER_TICK lines each 50 ms, scrolled once: a chatty
        // command cannot hold the main loop.
        glib::timeout_add_local(Duration::from_millis(50), move || {
            let mut added = false;
            for _ in 0..LINES_PER_TICK {
                match rx.try_recv() {
                    Ok(Event::Line(stream, text)) => {
                        ui.pane.line(stream, &text);
                        added = true;
                    }
                    Ok(end) => {
                        ui.pane.scroll_to_end();
                        ui.end(&id, end);
                        return glib::ControlFlow::Break;
                    }
                    Err(std::sync::mpsc::TryRecvError::Empty) => break,
                    Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                        ui.end(&id, Event::Failed("the command's output stopped with no exit".into()));
                        return glib::ControlFlow::Break;
                    }
                }
            }
            // Only new output scrolls: someone reading back is left there.
            if added {
                ui.pane.scroll_to_end();
            }
            glib::ControlFlow::Continue
        });
    }

    fn end(self: &Rc<Self>, id: &str, end: Event) {
        if let Event::Failed(msg) = &end {
            self.pane.line(Stream::Stderr, msg);
        }
        let said = self.pane.finish(id, &end);
        self.bridges_pending.set(None);
        // A switch that did not happen goes back at once; one that did stays
        // on the new value until the next status read says so.
        if !log_pane::succeeded(id, &end) {
            self.selector_pending.set(None);
        }
        self.close_asked.set(None);
        self.set_busy(false);
        let done = self.headless.borrow_mut().take();
        if let Some(done) = done {
            return done(match end {
                Event::Exit(Exit::Code(c)) => c,
                Event::Exit(Exit::Signal(s)) => 128 + s,
                _ => 1,
            });
        }
        if !log_pane::succeeded(id, &end) {
            if selector_for(id).is_some() {
                self.toast(&format!("The switch did not happen: {said}"));
            } else {
                self.toast(&format!("{}: {said}", actions::lookup(id).map_or(id, |a| a.label)));
            }
        }
        // Re-read and redraw everything: a switch the command did not turn
        // goes back to what the status says. A read already under way is
        // from before the action and is dropped.
        self.read_gen.set(self.read_gen.get() + 1);
        self.shown.borrow_mut().take();
        self.refresh();
        if id == "update-check" && matches!(end, Event::Exit(Exit::Code(10))) {
            // The commit this check found: its `available <commit>` line.
            let found = self.pane.last_line_with_prefix("available ").map(|l| l["available ".len()..].trim().to_string());
            self.confirm_update(found);
        }
    }

    fn set_busy(self: &Rc<Self>, busy: bool) {
        self.busy.set(busy);
        let page = self.shown.borrow_mut().take();
        if let Some(page) = page {
            let status = self.status.borrow().clone();
            self.show(page, status);
        }
    }

    /// Ask before a switch to `sel.choices[idx]`. `combo` is the selector the
    /// person used (none when the pick came from `act`): anything but Switch
    /// puts it back on the installed value and runs nothing.
    fn ask_switch(self: &Rc<Self>, sel: Selector, idx: usize, combo: Option<adw::ComboRow>) {
        let back = move || {
            if let (Some(c), Some(i)) = (&combo, sel.installed) {
                c.set_selected(i as u32);
            }
        };
        if self.busy.get() {
            back();
            return self.toast("Another action is running");
        }
        let d = adw::AlertDialog::new(
            Some(&format!("Switch {} to {}?", sel.subject, sel.choices[idx])),
            Some("The stack is reinstalled from the kept source. This takes a few minutes and DNS stops briefly."),
        );
        d.add_responses(&[("cancel", "Not now"), ("switch", "Switch")]);
        d.set_response_appearance("switch", adw::ResponseAppearance::Suggested);
        d.set_close_response("cancel");
        let ui = Rc::clone(self);
        d.connect_response(None, move |_, r| {
            if r == "switch" {
                ui.run(sel.actions[idx], None);
            } else {
                back();
            }
        });
        d.present(Some(&self.window));
    }

    fn confirm_uninstall(self: &Rc<Self>) {
        let d = adw::AlertDialog::new(
            Some("Uninstall nice-dns?"),
            Some(
                "This removes the stack and what it keeps (Tor state, the Pi-hole lists, \
                 the admin password) and the nice-dns command, and gives DNS back to the \
                 system. Type uninstall to go ahead.",
            ),
        );
        let entry = gtk::Entry::builder().placeholder_text("uninstall").build();
        d.set_extra_child(Some(&entry));
        d.add_responses(&[("cancel", "Cancel"), ("uninstall", "Uninstall")]);
        d.set_response_appearance("uninstall", adw::ResponseAppearance::Destructive);
        d.set_response_enabled("uninstall", false);
        d.set_close_response("cancel");
        let dd = d.clone();
        entry.connect_changed(move |e| dd.set_response_enabled("uninstall", e.text() == "uninstall"));
        let ui = Rc::clone(self);
        d.connect_response(None, move |_, r| {
            if r == "uninstall" {
                ui.run("uninstall", None);
            }
        });
        d.present(Some(&self.window));
    }

    fn choose_reinstall(self: &Rc<Self>) {
        let rec = self.status.borrow().as_ref().map(|s| s.install.clone()).unwrap_or_default();
        // Choices the status could not tell (the install group unreadable)
        // are not guessed: the reinstall keeps the recorded ones.
        if rec.variant.is_none() || rec.pihole.is_none() {
            return self.confirm_plain_reinstall();
        }
        let variants = ["haproxy", "socat"];
        let flavours = ["standard", "hardened"];
        let pick = |list: &[&str], v: &Option<String>| {
            v.as_deref().and_then(|v| list.iter().position(|x| *x == v)).unwrap_or(0) as u32
        };
        let variant = gtk::DropDown::from_strings(&variants);
        variant.set_selected(pick(&variants, &rec.variant));
        let flavour = gtk::DropDown::from_strings(&flavours);
        flavour.set_selected(pick(&flavours, &rec.pihole));
        let branch = gtk::Entry::builder().text(rec.branch.clone().unwrap_or_else(|| "main".into())).build();
        let grid = gtk::Grid::builder().row_spacing(6).column_spacing(12).build();
        for (i, (name, w)) in [("Proxy", variant.upcast_ref::<gtk::Widget>()), ("Pi-hole", flavour.upcast_ref()), ("Branch", branch.upcast_ref())]
            .into_iter()
            .enumerate()
        {
            grid.attach(&gtk::Label::builder().label(name).xalign(0.0).build(), 0, i as i32, 1, 1);
            grid.attach(w, 1, i as i32, 1, 1);
        }
        let d = adw::AlertDialog::new(
            Some("Reinstall nice-dns?"),
            Some("The new stack is prepared first; the running one is replaced only when it is ready, and comes back if anything fails."),
        );
        d.set_extra_child(Some(&grid));
        d.add_responses(&[("cancel", "Cancel"), ("reinstall", "Reinstall")]);
        d.set_response_appearance("reinstall", adw::ResponseAppearance::Suggested);
        d.set_close_response("cancel");
        let ui = Rc::clone(self);
        d.connect_response(None, move |_, r| {
            if r != "reinstall" {
                return;
            }
            let c = Choices {
                variant: variants[variant.selected() as usize % variants.len()].into(),
                pihole: flavours[flavour.selected() as usize % flavours.len()].into(),
                branch: branch.text().to_string(),
            };
            match c.words() {
                Ok(_) => ui.run("reinstall", Some(&c)),
                Err(e) => ui.toast(&format!("Not reinstalled: {e}")),
            }
        });
        d.present(Some(&self.window));
    }

    /// Reinstall with the recorded choices, asked first.
    fn confirm_plain_reinstall(self: &Rc<Self>) {
        let d = adw::AlertDialog::new(
            Some("Reinstall nice-dns?"),
            Some("The status does not say which choices are installed, so the reinstall keeps the recorded ones."),
        );
        d.add_responses(&[("cancel", "Cancel"), ("reinstall", "Reinstall")]);
        d.set_response_appearance("reinstall", adw::ResponseAppearance::Suggested);
        d.set_close_response("cancel");
        let ui = Rc::clone(self);
        d.connect_response(None, move |_, r| {
            if r == "reinstall" {
                ui.run("reinstall", None);
            }
        });
        d.present(Some(&self.window));
    }

    /// Ask before `nice-dns update`. `found`: the commit a check just found;
    /// otherwise the last check's, from the status.
    fn confirm_update(self: &Rc<Self>, found: Option<String>) {
        let commit = found.or_else(|| self.status.borrow().as_ref().and_then(|s| s.update.remote_commit.clone()));
        let body = match commit {
            Some(c) => format!(
                "The branch's commit {} is installed like a reinstall, with the recorded choices. The stack restarts.",
                short(&c)
            ),
            None => "The branch's current commit is installed like a reinstall, with the recorded choices. The stack restarts.".into(),
        };
        let d = adw::AlertDialog::new(Some("Install the update?"), Some(&body));
        d.add_responses(&[("cancel", "Not now"), ("update", "Install")]);
        d.set_response_appearance("update", adw::ResponseAppearance::Suggested);
        d.set_close_response("cancel");
        let ui = Rc::clone(self);
        d.connect_response(None, move |_, r| {
            if r == "update" {
                ui.run("update", None);
            }
        });
        d.present(Some(&self.window));
    }

    /// The actions that run no command: the admin page and the password path.
    pub fn act_local(&self, id: &str) {
        let admin = self.status.borrow().as_ref().map(|s| s.admin.clone()).unwrap_or_default();
        match id {
            "open-admin" => match admin.url {
                Some(url) => {
                    if let Err(e) = gio::AppInfo::launch_default_for_uri(&url, None::<&gio::AppLaunchContext>) {
                        self.toast(&format!("Could not open {url}: {e}"));
                    }
                }
                None => self.toast("The status names no admin page"),
            },
            "show-password-path" => match admin.password_path {
                Some(p) => self.toast(&format!("The admin password is in {p}")),
                None => self.toast("The status names no password file"),
            },
            other => self.toast(&format!("{other}: not available here")),
        }
    }

    pub fn toast(&self, text: &str) {
        let t = adw::Toast::new(text);
        t.set_use_markup(false);
        t.set_timeout(8);
        *self.last_toast.borrow_mut() = text.to_string();
        self.toasts.add_toast(t);
    }

    /// Show a page; a page equal to the one shown changes nothing, so the
    /// scroll position stays.
    pub fn show(self: &Rc<Self>, page: Page, status: Option<Status>) {
        *self.status.borrow_mut() = status;
        if self.shown.borrow().as_ref() == Some(&page) {
            return;
        }
        let keep = self.scroller.vadjustment().value();
        match &page {
            Page::Installed(b) => {
                self.title.set_subtitle(&b.subtitle);
                match &b.update_available {
                    Some(text) => {
                        self.banner.set_title(text);
                        self.banner.set_revealed(true);
                    }
                    None => self.banner.set_revealed(false),
                }
                self.scroller.set_child(Some(&self.render_body(b)));
            }
            Page::NotInstalled { hint, can_install, unreadable } => {
                self.title.set_subtitle("not installed");
                self.banner.set_revealed(false);
                let page = adw::StatusPage::builder()
                    .icon_name("network-offline-symbolic")
                    .title("nice-dns is not installed")
                    .description("Install it with this line in a terminal:")
                    .build();
                let column = gtk::Box::new(gtk::Orientation::Vertical, 12);
                if let Some(h) = hint {
                    // Selectable, so it can be copied into a terminal.
                    let line = gtk::Label::builder().label(h.as_str()).selectable(true).wrap(true).build();
                    line.add_css_class("monospace");
                    column.append(&line);
                }
                for u in unreadable {
                    let l = gtk::Label::builder().label(format!("Could not read {u}")).wrap(true).build();
                    l.add_css_class("error");
                    column.append(&l);
                }
                if *can_install {
                    column.append(&self.button(INSTALL_ACTION));
                }
                page.set_child(Some(&column));
                self.scroller.set_child(Some(&page));
            }
            Page::Error(msg) => {
                self.title.set_subtitle("error");
                self.banner.set_revealed(false);
                let page = adw::StatusPage::builder()
                    .icon_name("dialog-error-symbolic")
                    .title("nice-dns cannot be read")
                    .description(glib::markup_escape_text(msg).as_str())
                    .build();
                self.scroller.set_child(Some(&page));
            }
        }
        let adj = self.scroller.vadjustment();
        glib::idle_add_local_once(move || adj.set_value(keep));
        *self.shown.borrow_mut() = Some(page);
    }

    fn button(self: &Rc<Self>, id: &'static str) -> gtk::Button {
        let label = actions::lookup(id).map_or(id, |a| a.label);
        let b = gtk::Button::with_label(label);
        b.set_widget_name(id);
        let weak = Rc::downgrade(self);
        b.connect_clicked(move |_| {
            if let Some(ui) = weak.upgrade() {
                ui.act(id);
            }
        });
        b.set_sensitive(!self.busy.get());
        b
    }

    /// The Proxy or Pi-hole selector: a combo row, disabled while an action
    /// runs or when `status` names no usable value (it then says `unknown`).
    fn selector_row(self: &Rc<Self>, r: &Row, sel: Selector) -> gtk::Widget {
        let names: &[&str] = if sel.installed.is_some() { &sel.choices } else { &["unknown"] };
        let shown = match self.selector_pending.get() {
            Some((kind, idx)) if kind == sel.kind => Some(idx),
            _ => sel.installed,
        };
        let combo = adw::ComboRow::builder()
            .title(r.title.as_str())
            .use_markup(false)
            .model(&gtk::StringList::new(names))
            .selected(shown.unwrap_or(0) as u32)
            .sensitive(!self.busy.get() && sel.installed.is_some())
            .build();
        combo.set_widget_name(&format!("selector-{}", sel.kind));
        // Connected after the value is set: only a person's pick asks.
        let weak = Rc::downgrade(self);
        combo.connect_selected_notify(move |c| {
            let (Some(ui), Some(installed)) = (weak.upgrade(), sel.installed) else { return };
            let idx = c.selected() as usize;
            if idx != installed && idx < sel.choices.len() && !ui.busy.get() {
                ui.ask_switch(sel, idx, Some(c.clone()));
            }
        });
        combo.upcast()
    }

    /// The last toast's text.
    pub fn last_toast(&self) -> String {
        self.last_toast.borrow().clone()
    }

    fn render_body(self: &Rc<Self>, b: &Body) -> gtk::Widget {
        let column = gtk::Box::new(gtk::Orientation::Vertical, 24);
        column.set_margin_top(18);
        column.set_margin_bottom(18);
        column.set_margin_start(12);
        column.set_margin_end(12);

        if !b.unreadable.is_empty() {
            let g = adw::PreferencesGroup::new();
            g.set_title("Some files could not be read");
            for u in &b.unreadable {
                let r = adw::ActionRow::builder().title(u.as_str()).use_markup(false).build();
                r.add_css_class("error");
                g.add(&r);
            }
            column.append(&g);
        }

        for s in &b.sections {
            let g = adw::PreferencesGroup::new();
            g.set_title(s.title);
            match (&s.note, s.greyed) {
                // The stale label: in the header, in the warning colour.
                (Some(n), true) => {
                    let l = gtk::Label::new(Some(n.as_str()));
                    l.add_css_class("warning");
                    l.add_css_class("heading");
                    g.set_header_suffix(Some(&l));
                }
                (Some(n), false) => g.set_description(Some(n.as_str())),
                (None, _) => {}
            }
            for r in &s.rows {
                let w: gtk::Widget = match &r.kind {
                    RowKind::BridgesSwitch(on) => {
                        let sw = adw::SwitchRow::builder()
                            .title(r.title.as_str())
                            .subtitle(r.subtitle.as_str())
                            .use_markup(false)
                            .active(self.bridges_pending.get().unwrap_or(*on))
                            .sensitive(!self.busy.get())
                            .build();
                        sw.set_widget_name("bridges");
                        let weak = Rc::downgrade(self);
                        sw.connect_active_notify(move |sw| {
                            if let Some(ui) = weak.upgrade() {
                                ui.act(BRIDGES_ACTIONS[usize::from(!sw.is_active())]);
                            }
                        });
                        sw.upcast()
                    }
                    RowKind::Selector(sel) => self.selector_row(r, *sel),
                    kind => {
                        let ar = adw::ActionRow::builder()
                            .title(r.title.as_str())
                            .subtitle(r.subtitle.as_str())
                            .use_markup(false)
                            .subtitle_selectable(true)
                            .build();
                        if let RowKind::Verdict(v) = kind {
                            let l = gtk::Label::new(Some(v));
                            // An old verdict is not shown in its colour.
                            l.add_css_class(match (s.greyed, v.as_str()) {
                                (true, _) => "dim-label",
                                (false, "healthy") => "success",
                                (false, "unhealthy") => "error",
                                _ => "warning",
                            });
                            ar.add_suffix(&l);
                        }
                        ar.upcast()
                    }
                };
                // Insensitive rows are drawn greyed; the section's buttons are
                // outside them and stay usable (Run checks now, for one).
                if s.greyed {
                    w.set_sensitive(false);
                }
                g.add(&w);
            }
            if !s.buttons.is_empty() {
                let bar = gtk::FlowBox::builder()
                    .selection_mode(gtk::SelectionMode::None)
                    .column_spacing(6)
                    .row_spacing(6)
                    .max_children_per_line(4)
                    .margin_top(6)
                    .build();
                for id in &s.buttons {
                    let btn = self.button(id);
                    if *id == "uninstall" {
                        btn.add_css_class("destructive-action");
                    }
                    bar.insert(&btn, -1);
                }
                g.add(&bar);
            }
            column.append(&g);
        }

        let clamp = adw::Clamp::builder().maximum_size(760).child(&column).build();
        clamp.upcast()
    }

    /// Read the status off the main loop and show it. A read still under way
    /// makes this a no-op.
    pub fn refresh(self: &Rc<Self>) {
        if self.reading.replace(true) {
            return;
        }
        let ui = Rc::clone(self);
        let gen = self.read_gen.get();
        glib::spawn_future_local(async move {
            let (page, status) = gio::spawn_blocking(read_page)
                .await
                .unwrap_or_else(|_| (Page::Error("the status reader stopped".into()), None));
            ui.reading.set(false);
            if gen != ui.read_gen.get() {
                // An action ended while this read ran: what it read may be
                // from before; read again rather than paint it.
                return ui.refresh();
            }
            // The status has the say now (not while an action runs: a read
            // then is one of the timer's, and the pick is still under way).
            if !ui.busy.get() {
                ui.selector_pending.set(None);
            }
            ui.show(page, status);
        });
    }

    /// Refresh now and every [`REFRESH`].
    pub fn start_refreshing(self: &Rc<Self>) {
        self.refresh();
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(REFRESH, move || match weak.upgrade() {
            Some(ui) => {
                ui.refresh();
                glib::ControlFlow::Continue
            }
            None => glib::ControlFlow::Break,
        });
    }

    /// Render the window into a PNG at `path` (the `--screenshot` hook).
    pub fn save_png(&self, path: &Path) -> Result<(), String> {
        let (w, h) = (self.window.width(), self.window.height());
        if w <= 0 || h <= 0 {
            return Err("the window has no size yet".into());
        }
        let paintable = gtk::WidgetPaintable::new(Some(&self.window));
        let snap = gtk::Snapshot::new();
        paintable.snapshot(&snap, f64::from(w), f64::from(h));
        let node = snap.to_node().ok_or("the window drew nothing")?;
        let renderer = self.window.renderer().ok_or("the window has no renderer")?;
        let rect = gtk::graphene::Rect::new(0.0, 0.0, w as f32, h as f32);
        let texture = renderer.render_texture(&node, Some(&rect));
        texture.save_to_png(path).map_err(|e| format!("{}: {e}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_794_251_900;

    fn page(fixture: &str, code: i32) -> Page {
        describe(&model::classify(Some(code), fixture), NOW, true)
    }

    fn body_of(p: Page) -> Body {
        match p {
            Page::Installed(b) => b,
            other => panic!("not an installed page: {other:?}"),
        }
    }

    fn section<'a>(b: &'a Body, id: &str) -> &'a Section {
        b.sections.iter().find(|s| s.id == id).unwrap_or_else(|| panic!("no section {id}"))
    }

    const INSTALLED: &str = include_str!("../../share/fixtures/status-installed.tsv");
    const STALE: &str = include_str!("../../share/fixtures/status-stale.tsv");
    const NOT_INSTALLED: &str = include_str!("../../share/fixtures/status-not-installed.tsv");
    const UPDATE: &str = include_str!("../../share/fixtures/status-update-available.tsv");

    #[test]
    fn window_installed_fixture_shows_every_section_fresh() {
        let b = body_of(page(INSTALLED, 0));
        let ids: Vec<_> = b.sections.iter().map(|s| s.id).collect();
        // What a person acts on first; the long observation list last.
        assert_eq!(ids, ["containers", "bridges", "controller", "installed", "admin", "recent", "observations"]);
        assert!(b.sections.iter().all(|s| !s.greyed), "a fresh controller greys nothing");
        assert!(b.subtitle.starts_with("generation 20261109T180318Z-nogit0000000 · socat"), "{}", b.subtitle);
        let c = section(&b, "containers");
        assert_eq!(c.rows.len(), 3);
        assert_eq!(c.rows[0].title, "pi-hole");
        assert_eq!(c.rows[0].kind, RowKind::Verdict("healthy".into()));
        assert_eq!(section(&b, "bridges").rows[0].kind, RowKind::BridgesSwitch(true));
        assert_eq!(b.update_available, None);
        assert_eq!(section(&b, "recent").rows.len(), 5);
    }

    #[test]
    fn window_stale_fixture_greys_the_controller_sections_with_the_stale_label() {
        let b = body_of(page(STALE, 0));
        for id in ["containers", "observations", "controller"] {
            let s = section(&b, id);
            assert!(s.greyed, "{id} not greyed");
            assert_eq!(s.note.as_deref(), Some("stale 942s"), "{id}");
        }
        for id in ["bridges", "installed", "admin"] {
            assert!(!section(&b, id).greyed, "{id} greyed");
        }
    }

    #[test]
    fn window_update_fixture_raises_the_banner() {
        let b = body_of(page(UPDATE, 0));
        let text = b.update_available.expect("no banner");
        assert!(text.starts_with("A different version is available: "), "{text}");
        assert_eq!(text.len(), "A different version is available: ".len() + 12);
    }

    #[test]
    fn window_not_installed_offers_install_only_with_the_kept_source() {
        let v = model::classify(Some(1), NOT_INSTALLED);
        match describe(&v, NOW, true) {
            Page::NotInstalled { hint, can_install, unreadable } => {
                assert!(hint.unwrap().starts_with("curl "));
                assert!(can_install);
                assert!(unreadable.is_empty());
            }
            other => panic!("{other:?}"),
        }
        assert!(matches!(describe(&v, NOW, false), Page::NotInstalled { can_install: false, .. }));
    }

    #[test]
    fn window_bridges_off_turns_the_switch_off_and_says_what_the_isp_sees() {
        let off = INSTALLED.replacen("bridges\tmode\ton", "bridges\tmode\toff", 1);
        let b = body_of(page(&off, 0));
        let s = section(&b, "bridges");
        assert_eq!(s.rows[0].kind, RowKind::BridgesSwitch(false));
        assert!(s.note.as_deref().unwrap().contains("ISP"));
    }

    #[test]
    fn window_unreadable_rows_are_listed() {
        let bad = INSTALLED.replacen("bridges\tcount\t7\n", "bridges\tunreadable\t~/x: permission denied\n", 1);
        let b = body_of(page(&bad, 2));
        assert_eq!(b.unreadable, ["bridges: ~/x: permission denied"]);
    }

    #[test]
    fn window_not_installed_with_an_unreadable_file_is_still_the_not_installed_page() {
        let both = format!("{NOT_INSTALLED}bridges\tunreadable\t~/x: permission denied\n");
        match page(&both, 2) {
            Page::NotInstalled { hint, unreadable, .. } => {
                assert!(hint.unwrap().starts_with("curl "));
                assert_eq!(unreadable, ["bridges: ~/x: permission denied"]);
            }
            other => panic!("an exit 2 with installed no shows {other:?}"),
        }
    }

    #[test]
    fn window_errors_become_one_error_page() {
        assert!(matches!(page("", 2), Page::Error(_)));
        assert!(matches!(page(INSTALLED, 5), Page::Error(_)));
    }

    #[test]
    fn window_every_button_is_an_action_in_the_table() {
        let b = body_of(page(INSTALLED, 0));
        for s in &b.sections {
            for id in &s.buttons {
                assert!(actions::lookup(id).is_some(), "{id} is not in actions.tsv");
            }
        }
    }

    fn selectors_of(b: &Body) -> Vec<Selector> {
        section(b, "installed")
            .rows
            .iter()
            .filter_map(|r| match r.kind {
                RowKind::Selector(s) => Some(s),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn window_installed_section_has_the_proxy_and_pihole_selectors_set_from_status() {
        let sel = selectors_of(&body_of(page(INSTALLED, 0)));
        assert_eq!(sel.iter().map(|s| (s.kind, s.installed)).collect::<Vec<_>>(), [("proxy", Some(1)), ("pihole", Some(0))]);
        assert_eq!(sel[0].choices, ["haproxy", "socat"]);
        assert_eq!(sel[1].choices, ["standard", "hardened"]);
    }

    #[test]
    fn window_a_selector_the_status_cannot_fill_is_unknown() {
        let no_variant: String = INSTALLED.lines().filter(|l| !l.starts_with("install\tvariant")).map(|l| format!("{l}\n")).collect();
        let sel = selectors_of(&body_of(page(&no_variant, 0)));
        assert_eq!((sel[0].installed, sel[1].installed), (None, Some(0)));
        let odd = INSTALLED.replacen("install\tpihole\tstandard", "install\tpihole\tparanoid", 1);
        let sel = selectors_of(&body_of(page(&odd, 0)));
        assert_eq!((sel[0].installed, sel[1].installed), (Some(1), None));
    }

    #[test]
    fn window_the_four_selector_actions_are_in_no_button_list() {
        let b = body_of(page(INSTALLED, 0));
        for s in &b.sections {
            for id in &s.buttons {
                assert!(selector_for(id).is_none(), "{id} is a button in {}", s.id);
            }
        }
        for id in ["proxy-haproxy", "proxy-socat", "pihole-standard", "pihole-hardened"] {
            assert!(selector_for(id).is_some(), "{id} is not a selector action");
        }
    }

    #[test]
    fn window_the_update_row_says_when_the_check_ran_whoever_ran_it() {
        // A scheduled check writes the same `checked_at` a manual one does.
        let scheduled = INSTALLED.replacen(
            "update\tresult\tunknown\tnever-checked\n",
            &format!("update\tresult\tcurrent\nupdate\tchecked_at\t{}\n", NOW - 7200),
            1,
        );
        let b = body_of(page(&scheduled, 0));
        let row = section(&b, "installed").rows.iter().find(|r| r.title == "Update").unwrap();
        assert_eq!(row.subtitle, "up to date (checked 2 h ago)");
    }

    /// The places an action can be offered, derived from what the window
    /// builds: each is (place, action id).
    fn places() -> Vec<(String, &'static str)> {
        let mut out: Vec<(String, &'static str)> = Vec::new();
        let b = body_of(page(INSTALLED, 0));
        for s in &b.sections {
            for id in &s.buttons {
                out.push((format!("buttons of {}", s.id), id));
            }
            for r in &s.rows {
                match r.kind {
                    RowKind::BridgesSwitch(_) => out.extend(BRIDGES_ACTIONS.iter().map(|id| ("the bridges switch".to_string(), *id))),
                    RowKind::Selector(sel) => out.extend(sel.actions.iter().map(|id| (format!("the {} selector", sel.kind), *id))),
                    _ => {}
                }
            }
        }
        // The banner shows when a check found a different version.
        if body_of(page(UPDATE, 0)).update_available.is_some() {
            out.push(("the update banner".into(), BANNER_ACTION));
        }
        // The not-installed page offers Install when the source is kept.
        if matches!(describe(&model::classify(Some(1), NOT_INSTALLED), NOW, true), Page::NotInstalled { can_install: true, .. }) {
            out.push(("the not-installed page".into(), INSTALL_ACTION));
        }
        out
    }

    #[test]
    fn every_action_has_one_place() {
        let places = places();
        let mut bad = Vec::new();
        for a in actions::all() {
            let at: Vec<&str> = places.iter().filter(|(_, id)| *id == a.id).map(|(p, _)| p.as_str()).collect();
            if at.len() != 1 {
                bad.push(format!("{}: {} place(s) {:?}", a.id, at.len(), at));
            }
        }
        for (place, id) in &places {
            if actions::lookup(id).is_none() {
                bad.push(format!("{place} offers {id}, which is not in actions.tsv"));
            }
        }
        assert!(bad.is_empty(), "{}", bad.join("\n"));
    }

    #[test]
    fn window_ago_says_minutes_and_hours() {
        assert_eq!(ago(NOW - 5, NOW), "just now");
        assert_eq!(ago(NOW - 300, NOW), "5 min ago");
        assert_eq!(ago(NOW - 7200, NOW), "2 h ago");
        assert_eq!(ago(NOW + 10, NOW), "in the future");
    }
}
