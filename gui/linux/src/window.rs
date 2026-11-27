//! The status window. `describe` turns what `nice-dns status --tsv` said into
//! a page description with no GTK in it, so the tests check it with no
//! display; `Ui` builds the widgets from that description and refreshes it
//! every 5 s. The window reports what the command says and never changes the
//! install itself (DEC-018): every change is an action the person starts.
//!
//! Three views (Overview, Checks, Setup) share one status level
//! (`level.rs`); Not installed, Error and Loading replace them.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::rc::Rc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use adw::prelude::*;
use gtk4 as gtk;
use gtk::{gio, glib};
use libadwaita as adw;

use crate::action_bar::{self, Bar};
use crate::actions::{self, Choices};
use crate::level::{self, CheckRow, Group, Hero, Level, Node, Repair, Severity, Tint, UpdateRow};
use crate::log_pane::{self, LogPane};
use crate::model::{self, Status, View};
use crate::runner::{self, Event, Exit, Stream};

#[cfg(test)]
use crate::level::ago;

/// How often the window reads `nice-dns status --tsv` again.
pub const REFRESH: Duration = Duration::from_secs(5);

/// How many output lines the pane takes per 50 ms tick.
const LINES_PER_TICK: usize = 200;

// ---------------------------------------------------------------- description

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Page {
    /// The rows were read (with or without `unreadable` groups).
    Installed(Box<Body>),
    /// `install installed no`; Install is offered only when the kept source
    /// exists, since `nice-dns install` runs from it. `unreadable`: the files
    /// `status` could not read (exit 2), one line each.
    NotInstalled { hint: Option<String>, can_install: bool, unreadable: Vec<String> },
    /// The command is missing, failed, or said something the contract does not.
    Error(String),
}

/// What the three views draw. Each action id appears in exactly one part (the
/// status header and the update row are one part each, drawn by two views).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Body {
    /// One function decides it (`level::level`); the hero, the path, the
    /// Checks badge and the dimming all read it.
    pub level: Level,
    /// The status header: title, subtitle and the one place of `health-run`.
    pub header: Hero,
    /// One line per `<group> unreadable <reason>` row.
    pub unreadable: Vec<String>,
    /// The five nodes of the lookup path, the sentence that reads them out
    /// and the line under them.
    pub path: Vec<Node>,
    pub path_sentence: String,
    pub path_footer: String,
    /// Checks that are not healthy, worst first, and the group's title.
    pub attention_title: String,
    pub attention: Vec<CheckRow>,
    /// The two links to Checks, at level `ok` only.
    pub links: Vec<String>,
    pub bridges: BridgesRow,
    pub admin: AdminRow,
    /// The update row: the one place of `update-check` and `update`.
    pub update: UpdateRow,
    pub checks_title: String,
    pub checks_subtitle: String,
    pub checks_total: usize,
    pub checks: Vec<Group>,
    pub auto_checks: AutoRow,
    pub repairs: Vec<Repair>,
    pub setup: Setup,
    /// The Checks tab's count: checks not healthy now (0 while the results
    /// are old).
    pub badge: usize,
    /// The window's accessible description; not drawn.
    pub subtitle: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgesRow {
    pub on: bool,
    pub subtitle: &'static str,
    /// "Bridges last refreshed {ago}".
    pub tooltip: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdminRow {
    pub subtitle: String,
    pub url: Option<String>,
    pub password_path: Option<String>,
}

/// "Check and repair automatically": on when the schedule is loaded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutoRow {
    pub on: bool,
    pub subtitle: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Setup {
    pub proxy: Selector,
    pub pihole: Selector,
    /// Under the two selectors.
    pub stack_note: &'static str,
    pub version: VersionRow,
    /// `helper installed no`: the only time the helper is mentioned.
    pub helper_missing: bool,
    pub maintenance: Vec<Maint>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionRow {
    pub title: String,
    pub subtitle: String,
    /// What "Copy build details" puts on the clipboard.
    pub details: String,
}

/// A row of Maintenance: one button, one action.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Maint {
    pub id: &'static str,
    pub title: &'static str,
    pub subtitle: &'static str,
    pub button: &'static str,
    pub destructive: bool,
}

/// A two-choice selector whose picks are rows of the action table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Selector {
    /// `proxy` or `pihole`: the widget is named `selector-<kind>`.
    pub kind: &'static str,
    pub title: &'static str,
    pub subtitle: &'static str,
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
    title: "Tor proxy",
    subtitle: "HAProxy is the default. socat is lighter.",
    subject: "the Tor proxy",
    choices: ["haproxy", "socat"],
    actions: ["proxy-haproxy", "proxy-socat"],
    installed: None,
};
const PIHOLE: Selector = Selector {
    kind: "pihole",
    title: "Pi-hole image",
    subtitle: "Hardened is a smaller build: about 109 MB instead of 700 MB.",
    subject: "Pi-hole",
    choices: ["standard", "hardened"],
    actions: ["pihole-standard", "pihole-hardened"],
    installed: None,
};

const STACK_NOTE: &str =
    "Changing either one rebuilds the stack: a few minutes, with a short DNS gap. The running stack stays if anything fails.";

/// The bridges switch's two actions: on, off.
const BRIDGES_ACTIONS: [&str; 2] = ["bridges-on", "bridges-off"];
/// The automatic-checks switch's two actions: on, off.
const AUTO_ACTIONS: [&str; 2] = ["health-start", "health-stop"];
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

fn or_unknown(v: &Option<String>) -> String {
    v.clone().unwrap_or_else(|| "unknown".into())
}

/// The page for what `status` said. `now` is the epoch the times are said
/// against; `can_install` whether the kept source exists.
pub fn describe(view: &View, now: u64, can_install: bool) -> Page {
    match view {
        View::Installed(s) | View::Unreadable(s) => Page::Installed(Box::new(body(s, now))),
        View::NotInstalled { hint, unreadable } => Page::NotInstalled {
            hint: hint.clone(),
            can_install,
            unreadable: unreadable.iter().map(|u| format!("{}: {}", u.group, u.reason)).collect(),
        },
        View::Error(msg) => Page::Error(format!("nice-dns status did not answer as expected: {msg}")),
    }
}

/// What "Copy build details" copies: one `key: value` line each.
fn build_details(s: &Status) -> String {
    let i = &s.install;
    [
        ("generation", &i.generation),
        ("source commit", &i.source_commit),
        ("branch", &i.branch),
        ("proxy", &i.variant),
        ("pihole", &i.pihole),
        ("platform", &i.platform),
        ("lock", &i.lock),
        ("helper", &s.helper.version),
    ]
    .iter()
    .map(|(k, v)| format!("{k}: {}\n", or_unknown(v)))
    .collect()
}

fn version_row(s: &Status) -> VersionRow {
    let i = &s.install;
    let title = match i.generation.as_deref().and_then(level::installed_on) {
        Some(d) => format!("Installed {d}"),
        None => "Installed".into(),
    };
    // A commit is a hex string; `unknown` (an install from a tree with no
    // .git) is not drawn as one.
    let commit = i.source_commit.as_deref().filter(|c| c.len() >= 7 && c.bytes().all(|b| b.is_ascii_hexdigit())).map(level::short);
    let subtitle = match (i.branch.as_deref(), commit) {
        (Some(b), Some(c)) => format!("Branch {b} at {c}"),
        (Some(b), None) => format!("Branch {b}"),
        (None, Some(c)) => format!("Commit {c}"),
        (None, None) => "Branch unknown".into(),
    };
    VersionRow { title, subtitle, details: build_details(s) }
}

fn body(s: &Status, now: u64) -> Body {
    let i = &s.install;
    let lvl = level::level(s);
    let header = level::hero(s, lvl, now);
    let attention = level::attention(s);
    let repairs = level::repairs(s, now);
    let (path, path_footer) = level::path(s, lvl);

    let mut sub = vec![header.title.clone()];
    if let Some(v) = &i.variant {
        sub.push(v.clone());
    }
    if let Some(p) = &i.pihole {
        sub.push(format!("{p} Pi-hole"));
    }
    if let Some(b) = &i.branch {
        sub.push(format!("branch {b}"));
    }

    let on = s.bridges.mode.as_deref() != Some("off");
    let mut links = Vec::new();
    if lvl == Level::Ok {
        links.push(level::checks_title(s));
        links.extend(level::last_repair_link(&repairs));
    }
    let maint = |id, title, subtitle, button, destructive| Maint { id, title, subtitle, button, destructive };
    Body {
        level: lvl,
        header,
        unreadable: s.unreadable.iter().map(|u| format!("{}: {}", u.group, u.reason)).collect(),
        path_sentence: level::path_sentence(&path),
        path,
        path_footer,
        attention_title: level::attention_title(attention.len()),
        badge: if matches!(lvl, Level::Attention | Level::Down) { attention.len() } else { 0 },
        attention,
        links,
        bridges: BridgesRow { on, subtitle: level::bridges_subtitle(on), tooltip: level::bridges_tooltip(s, now) },
        admin: AdminRow {
            subtitle: level::admin_subtitle(s.admin.url.as_deref()),
            url: s.admin.url.clone(),
            password_path: s.admin.password_path.clone(),
        },
        update: level::update_row(s, now),
        checks_title: level::checks_title(s),
        checks_subtitle: level::checks_subtitle(s, now),
        checks_total: s.obs.len(),
        checks: level::groups(s),
        auto_checks: AutoRow {
            on: s.controller.schedule.as_deref() == Some("loaded"),
            subtitle: if s.controller.mode.as_deref() == Some("shadow") {
                "Shadow mode: checks run, repairs do not."
            } else {
                "Runs on a schedule and repairs what it can. Also looks for updates twice a day."
            },
        },
        repairs,
        setup: Setup {
            proxy: selector(PROXY, &i.variant),
            pihole: selector(PIHOLE, &i.pihole),
            stack_note: STACK_NOTE,
            version: version_row(s),
            helper_missing: s.helper.installed == Some(false),
            maintenance: vec![
                maint("restart", "Restart the stack", "Restarts every container. Tor reconnects in about a minute.", "Restart", false),
                maint("reinstall", "Reinstall", "Rebuild with another branch, proxy or Pi-hole image.", "Reinstall\u{2026}", false),
                maint("uninstall", "Uninstall nice-dns", "Gives DNS back to the system, then removes the stack and this app.", "Uninstall\u{2026}", true),
            ],
        },
        subtitle: sub.join(" \u{b7} "),
    }
}

// ------------------------------------------------------------------- reading

/// Whether `nice-dns install` has the source it runs from.
fn source_kept() -> bool {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join(".local/share/nice-dns/source/lib/install.sh").is_file()
}

/// The epoch the times are said against. `NICE_DNS_GUI_NOW`, when set to a
/// number, replaces the clock: for proofs and screenshots of the fixtures
/// (whose times are fixed), not for users.
fn now() -> u64 {
    if let Some(n) = std::env::var("NICE_DNS_GUI_NOW").ok().and_then(|v| v.trim().parse().ok()) {
        return n;
    }
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

/// The three views, in the order of the switcher: (page name, title, icon).
/// The wide switcher draws an icon beside each title; a page with none shows
/// the missing-image glyph.
const VIEWS: [(&str, &str, &str); 3] = [
    ("overview", "Overview", "nice-dns-shield-symbolic"),
    ("checks", "Checks", "nice-dns-check-circle-symbolic"),
    ("setup", "Setup", "emblem-system-symbolic"),
];

pub struct Ui {
    pub window: adw::ApplicationWindow,
    /// `views` (the three-view stack) or `other` (Not installed, Error,
    /// Loading).
    root: gtk::Stack,
    stack: adw::ViewStack,
    switcher: adw::ViewSwitcher,
    /// One scroller per view, in `VIEWS` order, and the one of `other`.
    views: [gtk::ScrolledWindow; 3],
    other: gtk::ScrolledWindow,
    toasts: adw::ToastOverlay,
    /// The running or last action's output.
    pub pane: LogPane,
    /// The bar at the bottom while an action runs and after it ends, and
    /// the drawer with the pane's output.
    bar: Rc<Bar>,
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
    /// The same for the automatic-checks switch (health-start / health-stop).
    auto_pending: Cell<Option<bool>>,
    /// The selector pick a running switch asked for (selector kind, choice
    /// index): the selector shows it until the status says what came of it.
    selector_pending: Cell<Option<(&'static str, usize)>>,
    /// While a selector's list or the switch question is open, a redraw would
    /// replace the selector under the person: `show` keeps the latest page in
    /// `held` instead, and it is drawn when the last hold is released.
    holds: Cell<u32>,
    held: RefCell<Option<(Page, Option<Status>)>>,
    /// The last toast's text (the probe hook reports it).
    last_toast: RefCell<String>,
    /// Which expanders the person opened or closed (key: `group:<title>` or
    /// `check:<id>`): a redraw keeps them.
    open: RefCell<HashMap<String, bool>>,
}

/// `w` and every widget under it.
fn walk_widgets(w: &gtk::Widget, f: &mut dyn FnMut(&gtk::Widget)) {
    f(w);
    let mut child = w.first_child();
    while let Some(c) = child {
        walk_widgets(&c, f);
        child = c.next_sibling();
    }
}

fn scroller() -> gtk::ScrolledWindow {
    gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).build()
}

impl Ui {
    pub fn new(app: &adw::Application) -> Rc<Ui> {
        crate::theme::init();

        let stack = adw::ViewStack::new();
        let views = [scroller(), scroller(), scroller()];
        for ((name, title, icon_name), v) in VIEWS.iter().zip(&views) {
            stack.add_titled_with_icon(v, Some(name), title, icon_name);
        }
        let switcher = adw::ViewSwitcher::builder().policy(adw::ViewSwitcherPolicy::Wide).stack(&stack).build();
        let other = scroller();
        let loading = adw::StatusPage::builder().title("Reading the status").description("nice-dns status --tsv").build();
        let spin = gtk::Spinner::builder().spinning(true).halign(gtk::Align::Center).width_request(32).height_request(32).build();
        loading.set_child(Some(&spin));
        other.set_child(Some(&loading));
        let root = gtk::Stack::new();
        root.add_named(&stack, Some("views"));
        root.add_named(&other, Some("other"));
        root.set_visible_child_name("other");
        switcher.set_visible(false);

        let header = adw::HeaderBar::new();
        let name = gtk::Label::new(Some("nice-dns"));
        name.add_css_class("heading");
        header.pack_start(&name);
        header.set_title_widget(Some(&switcher));

        let pane = LogPane::new();
        let bar = Bar::new(pane.widget.upcast_ref());

        let toasts = adw::ToastOverlay::new();
        toasts.set_child(Some(&root));
        let view = adw::ToolbarView::new();
        view.add_top_bar(&header);
        view.set_content(Some(&toasts));
        view.add_bottom_bar(&bar.widget);

        let window = adw::ApplicationWindow::builder()
            .application(app)
            .title("nice-dns")
            .icon_name("nice-dns")
            .default_width(760)
            .default_height(760)
            .width_request(560)
            .height_request(520)
            .content(&view)
            .build();

        let ui = Rc::new(Ui {
            window,
            root,
            stack,
            switcher,
            views,
            other,
            toasts,
            pane,
            bar,
            shown: RefCell::new(None),
            status: RefCell::new(None),
            reading: Cell::new(false),
            read_gen: Cell::new(0),
            busy: Cell::new(false),
            headless: RefCell::new(None),
            close_asked: Cell::new(None),
            bridges_pending: Cell::new(None),
            auto_pending: Cell::new(None),
            selector_pending: Cell::new(None),
            holds: Cell::new(0),
            held: RefCell::new(None),
            last_toast: RefCell::new(String::new()),
            open: RefCell::new(HashMap::new()),
        });
        let weak = Rc::downgrade(&ui);
        let manager = adw::StyleManager::default();
        ui.pane.restyle(manager.is_dark());
        manager.connect_dark_notify(move |m| {
            if let Some(ui) = weak.upgrade() {
                ui.pane.restyle(m.is_dark());
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

    /// The status level of the page shown (`ok`, `attention`, ...), or `none`.
    pub fn level_summary(&self) -> &'static str {
        match self.shown.borrow().as_ref() {
            Some(Page::Installed(b)) => b.level.name(),
            Some(Page::NotInstalled { .. }) => Level::NotInstalled.name(),
            Some(Page::Error(_)) => Level::Error.name(),
            None => "none",
        }
    }

    /// Show view `name` (`overview`, `checks` or `setup`), when the three
    /// views are what the window shows.
    pub fn select_view(&self, name: &str) {
        if VIEWS.iter().any(|(n, _, _)| *n == name) {
            self.stack.set_visible_child_name(name);
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
        let argv = match actions::argv(id, choices, runner::resolve) {
            Ok(Some(v)) => v,
            Ok(None) => return self.act_local(id),
            Err(e) => {
                self.pane.start(&[]);
                return self.end(id, Event::Failed(e));
            }
        };
        match id {
            "bridges-on" => self.bridges_pending.set(Some(true)),
            "bridges-off" => self.bridges_pending.set(Some(false)),
            "health-start" => self.auto_pending.set(Some(true)),
            "health-stop" => self.auto_pending.set(Some(false)),
            _ => {}
        }
        if let Some((sel, idx)) = selector_for(id) {
            self.selector_pending.set(Some((sel.kind, idx)));
        }
        self.set_busy(true);
        self.pane.start(&argv);
        self.bar.running(&action_bar::running_title(id));
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
                if let Some(l) = ui.pane.last_line() {
                    ui.bar.latest(&l);
                }
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
        self.auto_pending.set(None);
        // A switch that did not happen goes back at once; one that did stays
        // on the new value until the next status read says so.
        if !log_pane::succeeded(id, &end) {
            self.selector_pending.set(None);
        }
        self.close_asked.set(None);
        // The bar says how it ended: a result, or "did not finish" with the
        // drawer open (a failure is no toast).
        if log_pane::succeeded(id, &end) {
            let title = action_bar::result_title(id, self.pane.last_line().as_deref());
            self.bar.finished(true, &title, &format!("Finished in {} \u{b7} {said}", self.bar.took()));
        } else {
            self.bar.finished(false, &action_bar::failed_title(id), &said);
        }
        self.set_busy(false);
        let done = self.headless.borrow_mut().take();
        if let Some(done) = done {
            return done(match end {
                Event::Exit(Exit::Code(c)) => c,
                Event::Exit(Exit::Signal(s)) => 128 + s,
                _ => 1,
            });
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
        if self.holds.get() > 0 {
            // Redrawn on release; a later page already held is the one drawn.
            if self.held.borrow().is_none() {
                if let Some(page) = self.shown.borrow_mut().take() {
                    *self.held.borrow_mut() = Some((page, self.status.borrow().clone()));
                }
            }
            return;
        }
        let page = self.shown.borrow_mut().take();
        if let Some(page) = page {
            let status = self.status.borrow().clone();
            self.show(page, status);
        }
    }

    /// Hold redraws (see `holds`).
    fn hold(&self) {
        self.holds.set(self.holds.get() + 1);
    }

    /// Release a hold; the last one draws the latest held page: at once, or,
    /// from inside a signal of a widget the redraw would replace
    /// (`later`), on the main loop's next turn.
    fn release(self: &Rc<Self>, later: bool) {
        let n = self.holds.get().saturating_sub(1);
        self.holds.set(n);
        if n > 0 {
            return;
        }
        let ui = Rc::clone(self);
        let draw = move || {
            if ui.holds.get() == 0 {
                let held = ui.held.borrow_mut().take();
                if let Some((page, status)) = held {
                    ui.shown.borrow_mut().take();
                    ui.show(page, status);
                }
            }
        };
        if later {
            glib::idle_add_local_once(draw);
        } else {
            draw();
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
            Some(
                "The stack is rebuilt from the kept source. This takes a few minutes and DNS stops briefly. \
                 The running stack stays if anything fails.",
            ),
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
            ui.release(false);
        });
        // The selector behind the question stays the one the person used.
        self.hold();
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
        for (i, (name, w)) in [("Tor proxy", variant.upcast_ref::<gtk::Widget>()), ("Pi-hole image", flavour.upcast_ref()), ("Branch", branch.upcast_ref())]
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
                level::short(&c)
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
    pub fn act_local(self: &Rc<Self>, id: &str) {
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
                Some(p) => self.reveal_password_file(&p),
                None => self.toast("The status names no password file"),
            },
            other => self.toast(&format!("{other}: not available here")),
        }
    }
    /// Show the admin password file in the file manager; when that cannot be
    /// done, say where it is, with a Copy button.
    fn reveal_password_file(self: &Rc<Self>, path: &str) {
        let weak = Rc::downgrade(self);
        let shown = path.to_string();
        gtk::FileLauncher::new(Some(&gio::File::for_path(path))).open_containing_folder(
            Some(&self.window),
            gio::Cancellable::NONE,
            move |res| {
                // A dismissed chooser is no failure.
                let Err(e) = res else { return };
                if e.matches(gtk::DialogError::Dismissed) {
                    return;
                }
                if let Some(ui) = weak.upgrade() {
                    ui.toast_with_copy(&format!("The admin password is in {shown}"), &shown);
                }
            },
        );
    }

    /// A toast with a Copy button that puts `copy` on the clipboard.
    fn toast_with_copy(&self, text: &str, copy: &str) {
        let t = adw::Toast::new(text);
        t.set_use_markup(false);
        t.set_timeout(15);
        t.set_button_label(Some("Copy"));
        let (clip, copy) = (self.window.clipboard(), copy.to_string());
        t.connect_button_clicked(move |_| clip.set_text(&copy));
        *self.last_toast.borrow_mut() = text.to_string();
        self.toasts.add_toast(t);
    }

    /// The bar in one line (the probe hook reports it).
    pub fn bar_summary(&self) -> String {
        self.bar.summary()
    }

    pub fn toast(&self, text: &str) {
        let t = adw::Toast::new(text);
        t.set_use_markup(false);
        t.set_timeout(8);
        *self.last_toast.borrow_mut() = text.to_string();
        self.toasts.add_toast(t);
    }

    /// Show a page; a page equal to the one shown changes nothing, so the
    /// scroll positions stay. A different one rebuilds the views, keeping each
    /// view's scroll position and the expanders the person opened.
    pub fn show(self: &Rc<Self>, page: Page, status: Option<Status>) {
        if self.holds.get() > 0 {
            *self.held.borrow_mut() = Some((page, status));
            return;
        }
        *self.status.borrow_mut() = status;
        if self.shown.borrow().as_ref() == Some(&page) {
            return;
        }
        let keep: Vec<(gtk::Adjustment, f64)> = self
            .views
            .iter()
            .chain(std::iter::once(&self.other))
            .map(|s| {
                let a = s.vadjustment();
                let v = a.value();
                (a, v)
            })
            .collect();
        match &page {
            Page::Installed(b) => {
                self.views[0].set_child(Some(&self.render_overview(b)));
                self.views[1].set_child(Some(&self.render_checks(b)));
                self.views[2].set_child(Some(&self.render_setup(b)));
                let checks = self.stack.page(&self.views[1]);
                checks.set_badge_number(b.badge as u32);
                checks.set_needs_attention(b.badge > 0);
                self.window.update_property(&[gtk::accessible::Property::Description(&b.subtitle)]);
                self.switcher.set_visible(true);
                self.root.set_visible_child_name("views");
            }
            Page::NotInstalled { hint, can_install, unreadable } => {
                let page = adw::StatusPage::builder()
                    .icon_name("network-offline-symbolic")
                    .title("nice-dns is not installed")
                    .description("Install it with this line in a terminal:")
                    .build();
                let column = gtk::Box::new(gtk::Orientation::Vertical, 12);
                column.set_halign(gtk::Align::Center);
                if let Some(h) = hint {
                    // Selectable, so it can be copied into a terminal; the
                    // button copies it for the person.
                    let line = gtk::Label::builder().label(h.as_str()).selectable(true).can_focus(false).wrap(true).wrap_mode(gtk::pango::WrapMode::WordChar).xalign(0.0).hexpand(true).build();
                    line.add_css_class("nd-record");
                    let copy = gtk::Button::with_label("Copy");
                    copy.set_valign(gtk::Align::Center);
                    let (weak, text) = (Rc::downgrade(self), h.clone());
                    copy.connect_clicked(move |_| {
                        if let Some(ui) = weak.upgrade() {
                            ui.copy_text(&text, "Install line copied");
                        }
                    });
                    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
                    row.append(&line);
                    row.append(&copy);
                    column.append(&row);
                }
                for u in unreadable {
                    let l = gtk::Label::builder().label(format!("Could not read {u}")).wrap(true).build();
                    l.add_css_class("error");
                    column.append(&l);
                }
                if *can_install {
                    let b = self.action_button(INSTALL_ACTION, "Install nice-dns");
                    b.add_css_class("suggested-action");
                    b.set_halign(gtk::Align::Center);
                    column.append(&b);
                }
                page.set_child(Some(&clamp(&column, 620)));
                self.other.set_child(Some(&page));
                self.switcher.set_visible(false);
                self.root.set_visible_child_name("other");
            }
            Page::Error(msg) => {
                let page = adw::StatusPage::builder()
                    .icon_name("dialog-error-symbolic")
                    .title("nice-dns cannot be read")
                    .description(glib::markup_escape_text(msg).as_str())
                    .build();
                let copy = gtk::Button::with_label("Copy details");
                copy.set_halign(gtk::Align::Center);
                let (weak, text) = (Rc::downgrade(self), msg.clone());
                copy.connect_clicked(move |_| {
                    if let Some(ui) = weak.upgrade() {
                        ui.copy_text(&text, "Details copied");
                    }
                });
                page.set_child(Some(&copy));
                self.other.set_child(Some(&page));
                self.switcher.set_visible(false);
                self.root.set_visible_child_name("other");
            }
        }
        glib::idle_add_local_once(move || {
            for (a, v) in keep {
                a.set_value(v);
            }
        });
        *self.shown.borrow_mut() = Some(page);
    }

    /// Put `text` on the clipboard and say so.
    fn copy_text(&self, text: &str, said: &str) {
        self.window.clipboard().set_text(text);
        self.toast(said);
    }

    /// A button that asks for action `id`, disabled while an action runs.
    fn action_button(self: &Rc<Self>, id: &'static str, label: &str) -> gtk::Button {
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

    /// An expander row that remembers, across redraws, whether the person
    /// left it open (`key`); `default` is how it starts.
    fn remember(self: &Rc<Self>, key: String, default: bool, row: &adw::ExpanderRow) {
        row.set_expanded(self.open.borrow().get(&key).copied().unwrap_or(default));
        let weak = Rc::downgrade(self);
        row.connect_expanded_notify(move |r| {
            if let Some(ui) = weak.upgrade() {
                ui.open.borrow_mut().insert(key.clone(), r.is_expanded());
            }
        });
    }

    // ------------------------------------------------------------- overview

    fn render_overview(self: &Rc<Self>, b: &Body) -> gtk::Widget {
        let mut parts: Vec<gtk::Widget> = Vec::new();
        if !b.unreadable.is_empty() {
            let g = adw::PreferencesGroup::new();
            g.set_title("Some files could not be read");
            for u in &b.unreadable {
                let r = adw::ActionRow::builder().title(u.as_str()).use_markup(false).title_lines(0).build();
                r.add_prefix(&status_icon(Severity::Attention));
                g.add(&r);
            }
            parts.push(g.upcast());
        }
        parts.push(self.hero(b));
        parts.push(self.path_card(b));
        if !b.attention.is_empty() {
            parts.push(self.attention_group(b));
        }
        parts.push(self.controls_group(b));
        if !b.links.is_empty() {
            let g = adw::PreferencesGroup::new();
            for (i, text) in b.links.iter().enumerate() {
                let r = adw::ActionRow::builder().title(text.as_str()).use_markup(false).activatable(true).build();
                let (icon_name, class) = if i == 0 { ("nice-dns-check-circle-symbolic", "nd-icon-ok") } else { ("nice-dns-clock-symbolic", "dim-label") };
                let icon = gtk::Image::from_icon_name(icon_name);
                icon.add_css_class(class);
                r.add_prefix(&icon);
                r.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
                let weak = Rc::downgrade(self);
                r.connect_activated(move |_| {
                    if let Some(ui) = weak.upgrade() {
                        ui.select_view("checks");
                    }
                });
                g.add(&r);
            }
            parts.push(g.upcast());
        }
        column(&parts)
    }

    /// The status header with the hero: the one place of `health-run`.
    fn hero(self: &Rc<Self>, b: &Body) -> gtk::Widget {
        let h = &b.header;
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 18);
        // Not hexpand, whatever its glyph says: the title takes the room.
        let circle = gtk::Box::builder().valign(gtk::Align::Center).halign(gtk::Align::Start).hexpand(false).build();
        circle.add_css_class("nd-hero-circle");
        circle.add_css_class(tint_class(h.tint));
        let glyph = icon(h.icon, 30);
        glyph.set_hexpand(true);
        glyph.set_halign(gtk::Align::Center);
        circle.append(&glyph);
        let text = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(4).hexpand(true).valign(gtk::Align::Center).build();
        text.append(&gtk::Label::builder().label(h.title.as_str()).xalign(0.0).wrap(true).css_classes(["title-1"]).build());
        if !h.subtitle.is_empty() {
            text.append(&gtk::Label::builder().label(h.subtitle.as_str()).xalign(0.0).wrap(true).css_classes(["dim-label"]).build());
        }
        let button = self.action_button(h.button, h.button_label);
        button.set_valign(gtk::Align::Center);
        row.append(&circle);
        row.append(&text);
        row.append(&button);
        row.upcast()
    }

    /// "How a lookup travels": five nodes joined by lines and a footer.
    fn path_card(self: &Rc<Self>, b: &Body) -> gtk::Widget {
        let card = gtk::Box::new(gtk::Orientation::Vertical, 14);
        card.add_css_class("card");
        card.add_css_class("nd-path-card");
        card.append(&gtk::Label::builder().label("How a lookup travels").xalign(0.0).css_classes(["heading", "dim-label"]).build());
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        for (i, n) in b.path.iter().enumerate() {
            if i > 0 {
                let line = gtk::Box::builder().hexpand(true).valign(gtk::Align::Start).margin_top(23).width_request(10).build();
                line.add_css_class("nd-line");
                line.add_css_class(tint_class(n.state.tint()));
                if n.dashed_in {
                    line.add_css_class("nd-dashed");
                }
                row.append(&line);
            }
            let node = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(6).halign(gtk::Align::Center).valign(gtk::Align::Start).build();
            let circle = gtk::Box::builder().halign(gtk::Align::Center).build();
            circle.add_css_class("nd-node-circle");
            circle.add_css_class(tint_class(n.state.tint()));
            let glyph = icon(n.icon, 20);
            glyph.set_hexpand(true);
            glyph.set_halign(gtk::Align::Center);
            circle.append(&glyph);
            node.append(&circle);
            let label = gtk::Label::builder().label(n.label.as_str()).justify(gtk::Justification::Center).wrap(true).max_width_chars(12).build();
            label.add_css_class("nd-node-label");
            node.append(&label);
            let caption = gtk::Label::builder().label(n.caption.as_str()).justify(gtk::Justification::Center).wrap(true).max_width_chars(14).build();
            caption.add_css_class("nd-node-caption");
            match n.state {
                level::NodeState::Attention => caption.add_css_class("nd-attention"),
                level::NodeState::Down => caption.add_css_class("nd-down"),
                _ => {}
            }
            node.append(&caption);
            row.append(&node);
        }
        card.append(&row);
        card.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        card.append(&gtk::Label::builder().label(b.path_footer.as_str()).xalign(0.0).wrap(true).css_classes(["dim-label"]).build());
        card.update_property(&[gtk::accessible::Property::Label(&format!("{} {}", b.path_sentence, b.path_footer))]);
        card.upcast()
    }

    fn attention_group(self: &Rc<Self>, b: &Body) -> gtk::Widget {
        let g = adw::PreferencesGroup::new();
        g.set_title(&b.attention_title);
        let all = gtk::Button::builder().css_classes(["flat"]).build();
        let inner = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        inner.append(&gtk::Label::new(Some(&format!("All {} checks", b.checks_total))));
        inner.append(&gtk::Image::from_icon_name("go-next-symbolic"));
        all.set_child(Some(&inner));
        let weak = Rc::downgrade(self);
        all.connect_clicked(move |_| {
            if let Some(ui) = weak.upgrade() {
                ui.select_view("checks");
            }
        });
        g.set_header_suffix(Some(&all));
        for r in &b.attention {
            let row = adw::ActionRow::builder()
                .title(r.headline.as_str())
                .subtitle(r.reason.as_str())
                .use_markup(false)
                .title_lines(0)
                .subtitle_lines(0)
                .subtitle_selectable(true)
                .build();
            row.add_css_class("nd-mono-sub");
            row.add_prefix(&status_icon(r.severity));
            g.add(&row);
        }
        if b.level.old_results() {
            g.add_css_class("nd-dim");
        }
        g.upcast()
    }

    /// Tor bridges, the Pi-hole admin row and the update row.
    fn controls_group(self: &Rc<Self>, b: &Body) -> gtk::Widget {
        let g = adw::PreferencesGroup::new();

        let sw = adw::SwitchRow::builder()
            .title("Tor bridges")
            .subtitle(b.bridges.subtitle)
            .use_markup(false)
            .active(self.bridges_pending.get().unwrap_or(b.bridges.on))
            .sensitive(!self.busy.get())
            .build();
        sw.set_widget_name("bridges");
        sw.set_tooltip_text(b.bridges.tooltip.as_deref());
        let weak = Rc::downgrade(self);
        sw.connect_active_notify(move |sw| {
            if let Some(ui) = weak.upgrade() {
                ui.act(BRIDGES_ACTIONS[usize::from(!sw.is_active())]);
            }
        });
        g.add(&sw);

        let admin = adw::ActionRow::builder().title("Pi-hole admin").subtitle(b.admin.subtitle.as_str()).use_markup(false).build();
        let pw = self.action_button("show-password-path", "Password file");
        pw.add_css_class("flat");
        pw.set_valign(gtk::Align::Center);
        let open = self.action_button("open-admin", "Open");
        open.set_valign(gtk::Align::Center);
        let inner = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        inner.append(&gtk::Label::new(Some("Open")));
        inner.append(&icon("nice-dns-external-symbolic", 14));
        open.set_child(Some(&inner));
        open.update_property(&[gtk::accessible::Property::Label("Open the Pi-hole admin page")]);
        admin.add_suffix(&pw);
        admin.add_suffix(&open);
        g.add(&admin);

        g.add(&self.update_row_widget(&b.update));
        g.upcast()
    }

    /// The update row: one component, drawn in Overview and Setup.
    fn update_row_widget(self: &Rc<Self>, u: &UpdateRow) -> adw::ActionRow {
        let r = adw::ActionRow::builder().title(u.title).subtitle(u.subtitle.as_str()).use_markup(false).subtitle_lines(0).build();
        let btn = self.action_button(u.button, u.button_label);
        btn.set_valign(gtk::Align::Center);
        btn.add_css_class(if u.suggested { "suggested-action" } else { "flat" });
        r.add_suffix(&btn);
        r
    }

    // --------------------------------------------------------------- checks

    fn render_checks(self: &Rc<Self>, b: &Body) -> gtk::Widget {
        let mut parts: Vec<gtk::Widget> = Vec::new();

        // The same status header as the Overview's, as text and its button.
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 18);
        let text = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(4).hexpand(true).valign(gtk::Align::Center).build();
        text.append(&gtk::Label::builder().label(b.checks_title.as_str()).xalign(0.0).wrap(true).css_classes(["title-1"]).build());
        text.append(&gtk::Label::builder().label(b.checks_subtitle.as_str()).xalign(0.0).wrap(true).css_classes(["dim-label"]).build());
        let button = self.action_button(b.header.button, b.header.button_label);
        button.set_valign(gtk::Align::Center);
        head.append(&text);
        head.append(&button);
        parts.push(head.upcast());

        let g = adw::PreferencesGroup::new();
        let sw = adw::SwitchRow::builder()
            .title("Check and repair automatically")
            .subtitle(b.auto_checks.subtitle)
            .use_markup(false)
            .active(self.auto_pending.get().unwrap_or(b.auto_checks.on))
            .sensitive(!self.busy.get())
            .build();
        sw.set_widget_name("auto-checks");
        // Connected after the value is set: only a person's switch asks.
        let weak = Rc::downgrade(self);
        sw.connect_active_notify(move |sw| {
            if let Some(ui) = weak.upgrade() {
                ui.act(AUTO_ACTIONS[usize::from(!sw.is_active())]);
            }
        });
        g.add(&sw);
        parts.push(g.upcast());

        let groups = adw::PreferencesGroup::new();
        if b.checks.is_empty() {
            groups.add(&adw::ActionRow::builder().title("No checks recorded yet").subtitle("The controller has recorded no pass").build());
        }
        for grp in &b.checks {
            let er = adw::ExpanderRow::builder().title(grp.title).subtitle(grp.subtitle.as_str()).use_markup(false).build();
            let summary = gtk::Label::builder().label(grp.summary.as_str()).valign(gtk::Align::Center).build();
            summary.add_css_class(match grp.worst {
                Severity::Healthy => "nd-text-ok",
                Severity::Attention => "nd-text-attention",
                Severity::Down => "nd-text-down",
            });
            er.add_suffix(&summary);
            for r in &grp.rows {
                self.add_check_rows(&er, r);
            }
            self.remember(format!("group:{}", grp.title), grp.expanded, &er);
            groups.add(&er);
        }
        // Old results are dimmed, as the Checks rows were greyed before.
        if b.level.old_results() {
            groups.add_css_class("nd-dim");
        }
        parts.push(groups.upcast());

        let rep = adw::PreferencesGroup::new();
        rep.set_title("Automatic repairs");
        let failures = self.action_button("failures", "Show failures");
        failures.add_css_class("flat");
        rep.set_header_suffix(Some(&failures));
        if b.repairs.is_empty() {
            rep.add(&adw::ActionRow::builder().title("Nothing yet").subtitle("The controller's journal is empty").build());
        }
        for r in &b.repairs {
            let row = adw::ActionRow::builder().title(r.text.as_str()).use_markup(false).title_lines(0).build();
            row.add_suffix(&gtk::Label::builder().label(r.when.as_str()).css_classes(["dim-label"]).build());
            rep.add(&row);
        }
        parts.push(rep.upcast());
        column(&parts)
    }

    /// One check as a row in its group: its name and short value; activated,
    /// the row under it shows the raw record. (Rows nested in an expander row
    /// would take the parent's open arrow, so this is a plain row and a row
    /// that comes and goes.)
    fn add_check_rows(self: &Rc<Self>, group: &adw::ExpanderRow, r: &CheckRow) {
        let row = adw::ActionRow::builder().title(r.name.as_str()).use_markup(false).activatable(true).build();
        if r.severity != Severity::Healthy {
            row.set_subtitle(&r.headline);
            row.add_prefix(&status_icon(r.severity));
        }
        if r.in_use {
            row.add_suffix(&gtk::Label::builder().label("In use").valign(gtk::Align::Center).css_classes(["nd-pill"]).build());
        }
        if !r.value.is_empty() {
            let v = gtk::Label::builder()
                .label(r.value.as_str())
                .valign(gtk::Align::Center)
                .ellipsize(gtk::pango::EllipsizeMode::End)
                .max_width_chars(26)
                .css_classes(["dim-label"])
                .build();
            v.set_tooltip_text(Some(&r.reason));
            row.add_suffix(&v);
        }
        let arrow = gtk::Image::from_icon_name("pan-down-symbolic");
        row.add_suffix(&arrow);
        let record = gtk::Label::builder()
            .label(r.record.as_str())
            .selectable(true)
            .wrap(true)
            .wrap_mode(gtk::pango::WrapMode::WordChar)
            .xalign(0.0)
            .margin_top(4)
            .margin_bottom(10)
            .margin_start(12)
            .margin_end(12)
            .build();
        record.add_css_class("nd-record");
        let under = gtk::ListBoxRow::builder().activatable(false).selectable(false).child(&record).build();
        let key = format!("check:{}", r.id);
        let show = {
            let (under, arrow) = (under.clone(), arrow.clone());
            move |open: bool| {
                under.set_visible(open);
                arrow.set_icon_name(Some(if open { "pan-up-symbolic" } else { "pan-down-symbolic" }));
            }
        };
        show(self.open.borrow().get(&key).copied().unwrap_or(false));
        let weak = Rc::downgrade(self);
        row.connect_activated(move |_| {
            if let Some(ui) = weak.upgrade() {
                let now = !ui.open.borrow().get(&key).copied().unwrap_or(false);
                ui.open.borrow_mut().insert(key.clone(), now);
                show(now);
            }
        });
        row.update_property(&[gtk::accessible::Property::Description("Shows the raw record of this check")]);
        group.add_row(&row);
        group.add_row(&under);
    }

    // ---------------------------------------------------------------- setup

    fn render_setup(self: &Rc<Self>, b: &Body) -> gtk::Widget {
        let s = &b.setup;
        let mut parts: Vec<gtk::Widget> = Vec::new();

        let stack = adw::PreferencesGroup::new();
        stack.set_title("Stack");
        stack.set_description(Some(s.stack_note));
        stack.add(&self.selector_row(s.proxy));
        stack.add(&self.selector_row(s.pihole));
        parts.push(stack.upcast());

        let version = adw::PreferencesGroup::new();
        version.set_title("Version");
        let row = adw::ActionRow::builder().title(s.version.title.as_str()).subtitle(s.version.subtitle.as_str()).use_markup(false).build();
        let copy = gtk::Button::builder().label("Copy build details").valign(gtk::Align::Center).css_classes(["flat"]).build();
        copy.set_widget_name("copy-build-details");
        let (weak, text) = (Rc::downgrade(self), s.version.details.clone());
        copy.connect_clicked(move |_| {
            if let Some(ui) = weak.upgrade() {
                ui.copy_text(&text, "Build details copied");
            }
        });
        row.add_suffix(&copy);
        version.add(&row);
        version.add(&self.update_row_widget(&b.update));
        if s.helper_missing {
            let r = adw::ActionRow::builder()
                .title("Root helper is missing")
                .subtitle("Actions that need root will ask in a terminal.")
                .build();
            r.add_prefix(&status_icon(Severity::Attention));
            version.add(&r);
        }
        parts.push(version.upcast());

        let maint = adw::PreferencesGroup::new();
        maint.set_title("Maintenance");
        for m in &s.maintenance {
            let r = adw::ActionRow::builder().title(m.title).subtitle(m.subtitle).use_markup(false).build();
            let btn = self.action_button(m.id, m.button);
            btn.set_valign(gtk::Align::Center);
            if m.destructive {
                btn.add_css_class("flat");
                btn.add_css_class("error");
            }
            r.add_suffix(&btn);
            maint.add(&r);
        }
        parts.push(maint.upcast());
        column(&parts)
    }

    /// The Proxy or Pi-hole selector: a combo row, disabled while an action
    /// runs or when `status` names no usable value (it then says `unknown`).
    fn selector_row(self: &Rc<Self>, sel: Selector) -> gtk::Widget {
        let names: &[&str] = if sel.installed.is_some() { &sel.choices } else { &["unknown"] };
        let shown = match self.selector_pending.get() {
            Some((kind, idx)) if kind == sel.kind => Some(idx),
            _ => sel.installed,
        };
        let combo = adw::ComboRow::builder()
            .title(sel.title)
            .subtitle(sel.subtitle)
            .use_markup(false)
            .model(&gtk::StringList::new(names))
            .selected(shown.unwrap_or(0) as u32)
            .sensitive(!self.busy.get() && sel.installed.is_some())
            .build();
        combo.set_widget_name(&format!("selector-{}", sel.kind));
        // A redraw while the list is open would close it under the pointer.
        let mut popover = None;
        walk_widgets(combo.upcast_ref(), &mut |w| {
            if popover.is_none() {
                popover = w.downcast_ref::<gtk::Popover>().cloned();
            }
        });
        if let Some(p) = popover {
            let holding = Rc::new(Cell::new(false));
            let weak = Rc::downgrade(self);
            p.connect_visible_notify(move |p| {
                let Some(ui) = weak.upgrade() else { return };
                if p.is_visible() && !holding.replace(true) {
                    ui.hold();
                } else if !p.is_visible() && holding.replace(false) {
                    ui.release(true);
                }
            });
        }
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

/// The CSS class of a tint (`style.css`).
fn tint_class(t: Tint) -> &'static str {
    match t {
        Tint::Ok => "nd-ok",
        Tint::Attention => "nd-attention",
        Tint::Down => "nd-down",
        Tint::Neutral => "nd-neutral",
    }
}

/// A bundled symbolic icon at `px`.
fn icon(name: &str, px: i32) -> gtk::Image {
    gtk::Image::builder().icon_name(name).pixel_size(px).build()
}

/// The icon of a row that is not healthy; its own shape as well as its
/// colour, so the level never rests on colour alone.
fn status_icon(sev: Severity) -> gtk::Image {
    let i = gtk::Image::from_icon_name("nice-dns-warning-symbolic");
    i.add_css_class(if sev == Severity::Down { "nd-icon-down" } else { "nd-icon-attention" });
    i.update_property(&[gtk::accessible::Property::Label(if sev == Severity::Down { "Not working" } else { "Needs attention" })]);
    i
}

/// `max` px wide at most, centred, around `child`.
fn clamp(child: &impl IsA<gtk::Widget>, max: i32) -> adw::Clamp {
    adw::Clamp::builder().maximum_size(max).tightening_threshold(max).child(child).build()
}

/// One view's content: the parts in a column, 22 px apart, in a clamp.
fn column(parts: &[gtk::Widget]) -> gtk::Widget {
    let col = gtk::Box::new(gtk::Orientation::Vertical, 22);
    col.set_margin_top(24);
    col.set_margin_bottom(24);
    col.set_margin_start(24);
    col.set_margin_end(24);
    for p in parts {
        col.append(p);
    }
    clamp(&col, 660).upcast()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::level::NodeState;

    const NOW: u64 = 1_794_251_900;

    fn page(fixture: &str, code: i32) -> Page {
        describe(&model::classify(Some(code), fixture), NOW, true)
    }

    fn body_of(p: Page) -> Body {
        match p {
            Page::Installed(b) => *b,
            other => panic!("not an installed page: {other:?}"),
        }
    }

    fn body_for(fixture: &str) -> Body {
        body_of(page(fixture, 0))
    }

    const INSTALLED: &str = include_str!("../../share/fixtures/status-installed.tsv");
    const STALE: &str = include_str!("../../share/fixtures/status-stale.tsv");
    const NOT_INSTALLED: &str = include_str!("../../share/fixtures/status-not-installed.tsv");
    const UPDATE: &str = include_str!("../../share/fixtures/status-update-available.tsv");

    /// INSTALLED with one route unhealthy and another selected.
    fn attention_copy() -> String {
        INSTALLED
            .replacen(
                "obs\troute:cloudflare-onion\thealthy\t1930\trcode NOERROR in 0 ms via tor-socat:18531 as tor.cloudflare-dns.com",
                "obs\troute:cloudflare-onion\tunhealthy\t1930\tno answer via tor-socat:18531 as tor.cloudflare-dns.com",
                1,
            )
            .replacen("route\tselected\tcloudflare-onion\t73", "route\tselected\tcloudflare-exit\t74", 1)
    }

    /// Every string the Overview draws, for the acceptance checks.
    fn overview_text(b: &Body) -> String {
        let mut t = vec![b.header.title.clone(), b.header.subtitle.clone(), b.path_footer.clone(), b.path_sentence.clone()];
        for n in &b.path {
            t.push(format!("{} {}", n.label, n.caption));
        }
        t.extend(b.links.iter().cloned());
        t.extend([b.bridges.subtitle.to_string(), b.admin.subtitle.clone(), b.update.title.to_string(), b.update.subtitle.clone()]);
        t.join("\n")
    }

    fn has_16_hex(s: &str) -> bool {
        s.split(|c: char| !c.is_ascii_hexdigit()).any(|w| w.len() >= 16)
    }

    #[test]
    fn window_installed_fixture_shows_the_overview_parts_fresh() {
        let b = body_for(INSTALLED);
        assert_eq!(b.level, Level::Ok);
        assert_eq!(b.header.title, "DNS is protected");
        assert_eq!(b.header.button, "health-run");
        assert_eq!(b.path.len(), 5);
        assert!(b.path[1..].iter().all(|n| n.state == NodeState::Ok));
        assert!(b.attention.is_empty());
        assert_eq!(b.links, ["15 of 15 checks passing", "Last repair 1 h ago \u{b7} moved back to the Cloudflare onion route"]);
        assert!(b.bridges.on);
        assert_eq!(b.update.title, "Not checked yet");
        assert_eq!(b.badge, 0);
        assert_eq!(b.checks.len(), 3);
        assert!(b.auto_checks.on);
        assert_eq!(b.repairs.len(), 2);
        assert!(b.unreadable.is_empty());
        // SPEC 13: no "healthy", "generation" or 16-hex string on the Overview.
        let text = overview_text(&b);
        for bad in ["healthy", "generation"] {
            assert!(!text.contains(bad), "{bad} in the Overview:\n{text}");
        }
        assert!(!has_16_hex(&text), "{text}");
        assert!(b.subtitle.starts_with("DNS is protected \u{b7} socat \u{b7} standard Pi-hole"), "{}", b.subtitle);
    }

    #[test]
    fn window_one_unhealthy_route_with_another_selected_is_attention_with_a_badge() {
        let b = body_for(&attention_copy());
        assert_eq!(b.level, Level::Attention);
        assert_eq!(b.header.title, "DNS works, on a backup route");
        assert_eq!(b.badge, 1);
        assert_eq!(b.attention.len(), 1);
        assert_eq!(b.attention_title, "1 check needs attention");
        assert_eq!(b.attention[0].reason, "no answer via tor-socat:18531 as tor.cloudflare-dns.com");
        assert_eq!(b.checks_total, 15);
        // The links give way to the attention list.
        assert!(b.links.is_empty());
        assert_eq!(b.checks_title, "1 of 15 checks need attention");
    }

    #[test]
    fn window_dns_owner_unhealthy_is_down_and_names_the_check() {
        let text = INSTALLED.replacen(
            "obs\tdns-owner\thealthy\t7\t/etc/resolv.conf: nameserver 127.0.0.1 only",
            "obs\tdns-owner\tunhealthy\t7\t/etc/resolv.conf: nameserver 9.9.9.9",
            1,
        );
        let b = body_for(&text);
        assert_eq!(b.level, Level::Down);
        assert_eq!(b.header.title, "This computer is not using nice-dns");
        assert_eq!(b.header.subtitle, "/etc/resolv.conf: nameserver 9.9.9.9");
        assert_eq!(b.badge, 1);
    }

    #[test]
    fn window_stale_fixture_says_so_once_in_words_and_neutralises_the_path() {
        let b = body_for(STALE);
        assert_eq!(b.level, Level::Stale);
        assert_eq!(b.header.title, "Status is out of date");
        assert!(b.path.iter().all(|n| n.state == NodeState::Neutral));
        assert_eq!(b.badge, 0);
        // Nothing the window draws says "stale 942s".
        assert!(!format!("{b:?}").contains("stale 942s"));
        // The Checks rows are still there, to be dimmed.
        assert_eq!(b.checks.iter().map(|g| g.rows.len()).sum::<usize>(), 15);
        assert!(b.level.old_results());
    }

    #[test]
    fn window_stopped_schedule_turns_the_header_button_into_turn_on() {
        let b = body_for(&STALE.replacen("controller\tschedule\tloaded", "controller\tschedule\tstopped", 1));
        assert_eq!((b.header.title.as_str(), b.header.button), ("Automatic checks are off", "health-start"));
        assert!(!b.auto_checks.on);
    }

    #[test]
    fn window_update_fixture_has_no_banner_and_offers_install_in_the_update_row() {
        let b = body_for(UPDATE);
        assert_eq!((b.update.title, b.update.button, b.update.suggested), ("Update available", "update", true));
        assert_eq!(b.update.button_label, "Install\u{2026}");
        assert_eq!(b.update.subtitle, "Branch main is now at 0f6a6e7c3d2b, found just now.");
        assert_eq!(b.level, Level::Ok, "an available update is no status problem");
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
    fn window_bridges_off_turns_the_switch_off_and_says_what_the_provider_sees() {
        let off = INSTALLED.replacen("bridges\tmode\ton", "bridges\tmode\toff", 1);
        let b = body_for(&off);
        assert!(!b.bridges.on);
        assert!(b.bridges.subtitle.starts_with("Off. Your provider can see that Tor is in use."));
        assert_eq!(b.path[3].caption, "No bridges");
        assert_eq!(body_for(INSTALLED).bridges.tooltip.as_deref(), Some("Bridges have not been refreshed yet"));
    }

    #[test]
    fn window_unreadable_rows_are_listed() {
        let bad = INSTALLED.replacen("bridges\tcount\t7\n", "bridges\tunreadable\t~/x: permission denied\n", 1);
        let b = body_of(page(&bad, 2));
        assert_eq!(b.unreadable, ["bridges: ~/x: permission denied"]);
        assert_eq!(b.level, Level::Attention);
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
    fn window_the_admin_row_names_the_page_without_its_scheme() {
        let b = body_for(INSTALLED);
        assert_eq!(b.admin.subtitle, "Blocklists and query log at localhost:8880/admin");
        assert_eq!(b.admin.url.as_deref(), Some("http://localhost:8880/admin"));
        assert!(b.admin.password_path.unwrap().ends_with("pihole_webpassword"));
    }

    #[test]
    fn window_automatic_checks_follow_the_schedule_and_the_mode() {
        assert!(body_for(INSTALLED).auto_checks.on);
        let stopped = INSTALLED.replacen("controller\tschedule\tloaded", "controller\tschedule\tstopped", 1);
        assert!(!body_for(&stopped).auto_checks.on);
        let shadow = INSTALLED.replacen("controller\tmode\tactive", "controller\tmode\tshadow", 1);
        assert_eq!(body_for(&shadow).auto_checks.subtitle, "Shadow mode: checks run, repairs do not.");
    }

    fn selectors_of(b: &Body) -> [Selector; 2] {
        [b.setup.proxy, b.setup.pihole]
    }

    #[test]
    fn window_setup_has_the_proxy_and_pihole_selectors_set_from_status() {
        let sel = selectors_of(&body_for(INSTALLED));
        assert_eq!(sel.iter().map(|s| (s.kind, s.installed)).collect::<Vec<_>>(), [("proxy", Some(1)), ("pihole", Some(0))]);
        assert_eq!(sel[0].choices, ["haproxy", "socat"]);
        assert_eq!(sel[1].choices, ["standard", "hardened"]);
        assert_eq!((sel[0].title, sel[1].title), ("Tor proxy", "Pi-hole image"));
        assert_eq!(sel[0].subtitle, "HAProxy is the default. socat is lighter.");
        assert!(body_for(INSTALLED).setup.stack_note.starts_with("Changing either one rebuilds the stack"));
    }

    #[test]
    fn window_a_selector_the_status_cannot_fill_is_unknown() {
        let no_variant: String = INSTALLED.lines().filter(|l| !l.starts_with("install\tvariant")).map(|l| format!("{l}\n")).collect();
        let sel = selectors_of(&body_for(&no_variant));
        assert_eq!((sel[0].installed, sel[1].installed), (None, Some(0)));
        let odd = INSTALLED.replacen("install\tpihole\tstandard", "install\tpihole\tparanoid", 1);
        let sel = selectors_of(&body_for(&odd));
        assert_eq!((sel[0].installed, sel[1].installed), (Some(1), None));
    }

    #[test]
    fn window_the_four_selector_actions_are_in_no_button_list() {
        let b = body_for(INSTALLED);
        let buttons: Vec<&str> = [b.header.button, b.update.button]
            .into_iter()
            .chain(b.setup.maintenance.iter().map(|m| m.id))
            .chain(["show-password-path", "open-admin", "failures"])
            .collect();
        for id in buttons {
            assert!(selector_for(id).is_none(), "{id} is a button");
        }
        for id in ["proxy-haproxy", "proxy-socat", "pihole-standard", "pihole-hardened"] {
            assert!(selector_for(id).is_some(), "{id} is not a selector action");
        }
    }

    #[test]
    fn window_setup_version_maintenance_and_helper() {
        let b = body_for(INSTALLED);
        assert_eq!(b.setup.version.title, "Installed 9 November 2026");
        assert_eq!(b.setup.version.subtitle, "Branch main", "an unknown commit is not drawn as one");
        let d = &b.setup.version.details;
        for want in ["generation: 20261109T180318Z-nogit0000000\n", "branch: main\n", "proxy: socat\n", "pihole: standard\n", "platform: linux\n", "helper: 0.1.1\n", "lock: sha256:"] {
            assert!(d.contains(want), "{want} not in:\n{d}");
        }
        let b = body_for(UPDATE);
        assert_eq!(b.setup.version.subtitle, "Branch main at 4b5432d1e0a9");
        assert_eq!(b.setup.maintenance.iter().map(|m| m.id).collect::<Vec<_>>(), ["restart", "reinstall", "uninstall"]);
        assert!(b.setup.maintenance[2].destructive && !b.setup.maintenance[0].destructive);
        assert!(!b.setup.helper_missing);
        let no_helper = INSTALLED.replacen("helper\tinstalled\tyes", "helper\tinstalled\tno", 1);
        assert!(body_for(&no_helper).setup.helper_missing);
    }

    /// The places an action can be offered, derived from what the window
    /// builds: each is (place, action id). The status header and the update
    /// row are one place each, drawn by two views.
    fn places() -> Vec<(String, &'static str)> {
        let mut out: Vec<(String, &'static str)> = Vec::new();
        let b = body_for(INSTALLED);
        out.push(("the status header".into(), b.header.button));
        out.push(("the update row".into(), b.update.button));
        // `update` takes the update row's place when a different version is there.
        let avail = body_for(UPDATE);
        out.push(("the update row".into(), avail.update.button));
        out.extend(BRIDGES_ACTIONS.iter().map(|id| ("the bridges switch".to_string(), *id)));
        out.extend(["show-password-path", "open-admin"].map(|id| ("the Pi-hole admin row".to_string(), id)));
        out.extend(AUTO_ACTIONS.iter().map(|id| ("the automatic-checks switch".to_string(), *id)));
        out.push(("Automatic repairs".into(), "failures"));
        for sel in selectors_of(&b) {
            out.extend(sel.actions.iter().map(|id| (format!("the {} selector", sel.kind), *id)));
        }
        out.extend(b.setup.maintenance.iter().map(|m| (format!("Maintenance: {}", m.id), m.id)));
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
            // `update-check` and `update` share the update row, but each is
            // there once; so is `health-run` in the status header.
            if at.len() != 1 {
                bad.push(format!("{}: {} place(s) {:?}", a.id, at.len(), at));
            }
        }
        for (place, id) in &places {
            if actions::lookup(id).is_none() {
                bad.push(format!("{place} offers {id}, which is not in actions.tsv"));
            }
        }
        assert_eq!(actions::all().len(), 18);
        assert!(bad.is_empty(), "{}", bad.join("\n"));
    }

    #[test]
    fn window_ago_says_minutes_and_hours() {
        assert_eq!(ago(NOW - 5, NOW), "just now");
        assert_eq!(ago(NOW - 300, NOW), "5 min ago");
        assert_eq!(ago(NOW - 7200, NOW), "2 h ago");
        assert_eq!(ago(NOW + 10, NOW), "in the future");
    }

    #[test]
    fn window_the_update_row_says_when_the_check_ran_whoever_ran_it() {
        // A scheduled check writes the same `checked_at` a manual one does.
        let scheduled = INSTALLED.replacen(
            "update\tresult\tunknown\tnever-checked\n",
            &format!("update\tresult\tcurrent\nupdate\tchecked_at\t{}\n", NOW - 7200),
            1,
        );
        assert_eq!(body_for(&scheduled).update.subtitle, "Branch main, checked 2 h ago. nice-dns checks twice a day.");
    }
}
