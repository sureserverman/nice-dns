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

use crate::actions;
use crate::model::{self, Moment, Stale, Status, UpdateResult, View};

/// How often the window reads `nice-dns status --tsv` again.
pub const REFRESH: Duration = Duration::from_secs(5);

// ---------------------------------------------------------------- description

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Page {
    /// The rows were read (with or without `unreadable` groups).
    Installed(Body),
    /// `install installed no`; Install is offered only when the kept source
    /// exists, since `nice-dns install` runs from it.
    NotInstalled { hint: Option<String>, can_install: bool },
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
        View::NotInstalled(hint) => Page::NotInstalled { hint: hint.clone(), can_install },
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
            Some(c) => format!("An update is available: {}", short(c)),
            None => "An update is available".into(),
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
        row("Proxy", or_unknown(&i.variant)),
        row("Pi-hole", or_unknown(&i.pihole)),
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
            section("observations", "Observations", stale_note.clone(), greyed, observations, vec![]),
            section("bridges", "Bridges", bridges_note, false, vec![Row {
                title: "Use Tor bridges".into(),
                subtitle: bridges_sub,
                kind: RowKind::BridgesSwitch(on),
            }], vec![]),
            section(
                "controller",
                "Health controller",
                stale_note,
                greyed,
                controller,
                vec!["health-run", "health-start", "health-stop", "failures"],
            ),
            section("recent", "Recent actions", None, false, recent, vec![]),
            section("installed", "Installed", None, false, installed, vec!["update-check", "restart", "reinstall", "uninstall"]),
            section("admin", "Pi-hole admin", None, false, admin, vec!["open-admin", "show-password-path"]),
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
            let view = model::classify(o.status.code(), &String::from_utf8_lossy(&o.stdout));
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

/// What a button or the switch asks for: an action id from the table.
pub type OnAction = Rc<dyn Fn(&str)>;

pub struct Ui {
    pub window: adw::ApplicationWindow,
    title: adw::WindowTitle,
    banner: adw::Banner,
    toasts: adw::ToastOverlay,
    scroller: gtk::ScrolledWindow,
    /// Where the log pane goes (Task 1.3).
    pub bottom: gtk::Box,
    shown: RefCell<Option<Page>>,
    pub status: RefCell<Option<Status>>,
    reading: Cell<bool>,
    /// Buttons and the switch, disabled while an action runs.
    pub busy: Cell<bool>,
    on_action: RefCell<Option<OnAction>>,
}

impl Ui {
    pub fn new(app: &adw::Application) -> Rc<Ui> {
        let title = adw::WindowTitle::new("nice-dns", "");
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&title));

        let banner = adw::Banner::new("");
        banner.set_button_label(Some("Apply"));

        let scroller = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).build();
        let bottom = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let column = gtk::Box::new(gtk::Orientation::Vertical, 0);
        column.append(&banner);
        column.append(&scroller);
        column.append(&bottom);

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
            bottom,
            shown: RefCell::new(None),
            status: RefCell::new(None),
            reading: Cell::new(false),
            busy: Cell::new(false),
            on_action: RefCell::new(None),
        });
        let weak = Rc::downgrade(&ui);
        ui.banner.connect_button_clicked(move |_| {
            if let Some(ui) = weak.upgrade() {
                ui.act("update");
            }
        });
        ui
    }

    /// Who handles a button: Task 1.3's runner. Until one is set, only the
    /// two actions that run nothing work.
    pub fn set_on_action(&self, f: OnAction) {
        *self.on_action.borrow_mut() = Some(f);
    }

    pub fn act(&self, id: &str) {
        let handler = self.on_action.borrow().clone();
        match handler {
            Some(f) => f(id),
            None => self.act_local(id),
        }
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
            Page::NotInstalled { hint, can_install } => {
                self.title.set_subtitle("not installed");
                self.banner.set_revealed(false);
                let mut text = "Install it with this line in a terminal:".to_string();
                if let Some(h) = hint {
                    text = format!("{text}\n\n{}", glib::markup_escape_text(h));
                }
                let page = adw::StatusPage::builder()
                    .icon_name("network-offline-symbolic")
                    .title("nice-dns is not installed")
                    .description(text)
                    .build();
                if *can_install {
                    page.set_child(Some(&self.button("install")));
                }
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
                            .active(*on)
                            .sensitive(!self.busy.get())
                            .build();
                        sw.set_widget_name("bridges");
                        let weak = Rc::downgrade(self);
                        sw.connect_active_notify(move |sw| {
                            if let Some(ui) = weak.upgrade() {
                                ui.act(if sw.is_active() { "bridges-on" } else { "bridges-off" });
                            }
                        });
                        sw.upcast()
                    }
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
        glib::spawn_future_local(async move {
            let (page, status) = gio::spawn_blocking(read_page)
                .await
                .unwrap_or_else(|_| (Page::Error("the status reader stopped".into()), None));
            ui.reading.set(false);
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
        assert_eq!(ids, ["containers", "observations", "bridges", "controller", "recent", "installed", "admin"]);
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
        assert!(text.starts_with("An update is available: "), "{text}");
        assert_eq!(text.len(), "An update is available: ".len() + 12);
    }

    #[test]
    fn window_not_installed_offers_install_only_with_the_kept_source() {
        let v = model::classify(Some(1), NOT_INSTALLED);
        match describe(&v, NOW, true) {
            Page::NotInstalled { hint, can_install } => {
                assert!(hint.unwrap().starts_with("curl "));
                assert!(can_install);
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

    #[test]
    fn window_ago_says_minutes_and_hours() {
        assert_eq!(ago(NOW - 5, NOW), "just now");
        assert_eq!(ago(NOW - 300, NOW), "5 min ago");
        assert_eq!(ago(NOW - 7200, NOW), "2 h ago");
        assert_eq!(ago(NOW + 10, NOW), "in the future");
    }
}
