//! The action bar and the output drawer (SPEC 7). The bar sits at the bottom
//! of the window only while an action runs and after it ends: a spinner, the
//! action said in the present tense, the time it has taken and the command's
//! latest output line; when it ends, its result, or "did not finish" with the
//! drawer open. The drawer holds the log pane's whole output.

use std::cell::Cell;
use std::rc::Rc;
use std::time::{Duration, Instant};

use adw::prelude::*;
use gtk4 as gtk;
use gtk::glib;
use libadwaita as adw;

use crate::actions;

// ------------------------------------------------------------------ the words

/// The action said while it runs: "Switching the Tor proxy to haproxy".
pub fn running_title(id: &str) -> String {
    let fixed = match id {
        "install" => "Installing nice-dns",
        "reinstall" => "Reinstalling nice-dns",
        "restart" => "Restarting the stack",
        "uninstall" => "Uninstalling nice-dns",
        "update-check" => "Checking for updates",
        "update" => "Installing the update",
        "bridges-on" => "Turning Tor bridges on",
        "bridges-off" => "Turning Tor bridges off",
        "health-start" => "Turning on automatic checks",
        "health-stop" => "Turning off automatic checks",
        "health-run" => "Running checks",
        "failures" => "Reading recent failures",
        _ => "",
    };
    if !fixed.is_empty() {
        return fixed.to_string();
    }
    match crate::window::selector_for(id) {
        Some((sel, idx)) => format!("Switching {} to {}", sel.subject, sel.choices[idx]),
        None => actions::lookup(id).map_or(id, |a| a.label).to_string(),
    }
}

/// The result of an action that finished: the action's own last line where
/// the contract defines one, otherwise "{label}: finished".
pub fn result_title(id: &str, last_line: Option<&str>) -> String {
    let own = last_line.map(str::trim).filter(|l| match id {
        "bridges-on" | "bridges-off" => l.starts_with("Bridges are"),
        "update" => l.starts_with("updated to "),
        "update-check" => *l == "current",
        _ => crate::window::selector_for(id).is_some() && l.starts_with("Switched:"),
    });
    match own {
        Some(l) => l.to_string(),
        None => format!("{}: finished", actions::lookup(id).map_or(id, |a| a.label)),
    }
}

/// "{label} did not finish".
pub fn failed_title(id: &str) -> String {
    format!("{} did not finish", actions::lookup(id).map_or(id, |a| a.label))
}

/// A time taken: "12 s", "2 min 48 s", "1 h 5 min".
pub fn elapsed_text(secs: u64) -> String {
    match secs {
        s if s < 60 => format!("{s} s"),
        s if s < 3600 && s % 60 == 0 => format!("{} min", s / 60),
        s if s < 3600 => format!("{} min {} s", s / 60, s % 60),
        s if (s % 3600) / 60 == 0 => format!("{} h", s / 3600),
        s => format!("{} h {} min", s / 3600, (s % 3600) / 60),
    }
}

// ------------------------------------------------------------------- widgets

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Idle,
    Running,
    Finished,
    Failed,
}

impl State {
    fn name(self) -> &'static str {
        match self {
            State::Idle => "idle",
            State::Running => "running",
            State::Finished => "finished",
            State::Failed => "failed",
        }
    }
}

pub struct Bar {
    /// The drawer above the bar.
    pub widget: gtk::Box,
    bar: gtk::Revealer,
    drawer: gtk::Revealer,
    spinner: gtk::Spinner,
    icon: gtk::Image,
    title: gtk::Label,
    elapsed: gtk::Label,
    detail: gtk::Label,
    output: gtk::ToggleButton,
    close: gtk::Button,
    state: Cell<State>,
    started: Cell<Option<Instant>>,
    /// Bumped at each start: an older timer ends itself.
    tick: Cell<u64>,
}

impl Bar {
    /// `drawer` is the log pane's widget.
    pub fn new(drawer: &gtk::Widget) -> Rc<Bar> {
        let spinner = gtk::Spinner::builder().spinning(true).valign(gtk::Align::Center).build();
        let icon = gtk::Image::builder().pixel_size(20).valign(gtk::Align::Center).visible(false).build();
        let title = gtk::Label::builder().xalign(0.0).hexpand(false).wrap(true).css_classes(["heading"]).build();
        let elapsed = gtk::Label::builder().xalign(0.0).css_classes(["dim-label"]).build();
        let top = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        top.append(&title);
        top.append(&elapsed);
        let detail = gtk::Label::builder()
            .xalign(0.0)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .single_line_mode(true)
            .css_classes(["nd-bar-detail"])
            .build();
        let text = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(2).hexpand(true).valign(gtk::Align::Center).build();
        text.append(&top);
        text.append(&detail);
        let output = gtk::ToggleButton::builder().label("Show output").valign(gtk::Align::Center).build();
        let close = gtk::Button::builder().icon_name("window-close-symbolic").valign(gtk::Align::Center).css_classes(["flat", "circular"]).visible(false).build();
        close.set_tooltip_text(Some("Dismiss"));
        close.update_property(&[gtk::accessible::Property::Label("Dismiss")]);

        let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        row.set_margin_start(18);
        row.set_margin_end(14);
        row.set_margin_top(10);
        row.set_margin_bottom(10);
        row.set_height_request(38);
        row.append(&spinner);
        row.append(&icon);
        row.append(&text);
        row.append(&output);
        row.append(&close);

        let bar_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
        bar_box.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        bar_box.append(&row);
        let bar = gtk::Revealer::builder().transition_type(gtk::RevealerTransitionType::SlideUp).child(&bar_box).build();
        let drawer = gtk::Revealer::builder().transition_type(gtk::RevealerTransitionType::SlideUp).child(drawer).build();

        let widget = gtk::Box::new(gtk::Orientation::Vertical, 0);
        widget.append(&drawer);
        widget.append(&bar);

        let b = Rc::new(Bar {
            widget,
            bar,
            drawer,
            spinner,
            icon,
            title,
            elapsed,
            detail,
            output,
            close,
            state: Cell::new(State::Idle),
            started: Cell::new(None),
            tick: Cell::new(0),
        });
        let d = b.drawer.clone();
        b.output.connect_toggled(move |t| {
            d.set_reveal_child(t.is_active());
            t.set_label(if t.is_active() { "Hide output" } else { "Show output" });
        });
        let weak = Rc::downgrade(&b);
        b.close.connect_clicked(move |_| {
            if let Some(b) = weak.upgrade() {
                b.dismiss();
            }
        });
        b
    }

    /// An action starts: the spinner, its title and the time it has taken.
    pub fn running(self: &Rc<Self>, title: &str) {
        self.state.set(State::Running);
        self.started.set(Some(Instant::now()));
        self.spinner.set_visible(true);
        self.spinner.set_spinning(true);
        self.icon.set_visible(false);
        self.close.set_visible(false);
        self.title.set_text(title);
        self.elapsed.set_text(&format!("\u{b7} {}", elapsed_text(0)));
        self.detail.set_text("");
        self.bar.set_reveal_child(true);
        let gen = self.tick.get() + 1;
        self.tick.set(gen);
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_secs(1), move || match weak.upgrade() {
            Some(b) if b.tick.get() == gen && b.state.get() == State::Running => {
                let secs = b.started.get().map_or(0, |t| t.elapsed().as_secs());
                b.elapsed.set_text(&format!("\u{b7} {}", elapsed_text(secs)));
                glib::ControlFlow::Continue
            }
            _ => glib::ControlFlow::Break,
        });
    }

    /// The command's latest output line.
    pub fn latest(&self, line: &str) {
        if self.state.get() == State::Running {
            self.detail.set_text(line);
        }
    }

    /// How long the action ran, in words.
    pub fn took(&self) -> String {
        elapsed_text(self.started.get().map_or(0, |t| t.elapsed().as_secs()))
    }

    /// The action ended: its result, or "did not finish" with the drawer open.
    pub fn finished(&self, ok: bool, title: &str, detail: &str) {
        self.state.set(if ok { State::Finished } else { State::Failed });
        self.spinner.set_spinning(false);
        self.spinner.set_visible(false);
        self.icon.set_visible(true);
        self.icon.set_icon_name(Some(if ok { "nice-dns-check-circle-symbolic" } else { "nice-dns-warning-symbolic" }));
        self.icon.remove_css_class("nd-icon-ok");
        self.icon.remove_css_class("nd-icon-down");
        self.icon.add_css_class(if ok { "nd-icon-ok" } else { "nd-icon-down" });
        self.icon.update_property(&[gtk::accessible::Property::Label(if ok { "Finished" } else { "Did not finish" })]);
        self.title.set_text(title);
        self.elapsed.set_text("");
        self.detail.set_text(detail);
        self.close.set_visible(true);
        self.bar.set_reveal_child(true);
        if !ok {
            self.output.set_active(true);
        }
    }

    /// Close the bar (and the drawer with it).
    pub fn dismiss(&self) {
        if self.state.get() == State::Running {
            return;
        }
        self.state.set(State::Idle);
        self.bar.set_reveal_child(false);
        self.output.set_active(false);
    }

    /// One line for the probe hook: state, title, detail, drawer.
    pub fn summary(&self) -> String {
        format!(
            "state={} title={} detail={} drawer={}",
            self.state.get().name(),
            self.title.text().replace(' ', "_"),
            self.detail.text().replace(' ', "_"),
            if self.drawer.reveals_child() { "open" } else { "closed" }
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bar_running_titles_say_the_action_in_the_present_tense() {
        assert_eq!(running_title("proxy-haproxy"), "Switching the Tor proxy to haproxy");
        assert_eq!(running_title("pihole-hardened"), "Switching Pi-hole to hardened");
        assert_eq!(running_title("bridges-off"), "Turning Tor bridges off");
        assert_eq!(running_title("restart"), "Restarting the stack");
        assert_eq!(running_title("health-run"), "Running checks");
        // Every action that runs a command has words of its own.
        for a in actions::all().iter().filter(|a| a.program.is_some()) {
            let t = running_title(a.id);
            assert!(t.ends_with(|c: char| c.is_alphanumeric()) && t != a.label, "{}: {t}", a.id);
        }
    }

    #[test]
    fn bar_result_titles_use_the_actions_own_last_line_where_the_contract_has_one() {
        assert_eq!(
            result_title("bridges-on", Some("Bridges are on; the proxy restarted and DNS is answering.")),
            "Bridges are on; the proxy restarted and DNS is answering."
        );
        assert_eq!(result_title("update", Some("updated to 0f6a6e7c3d2b")), "updated to 0f6a6e7c3d2b");
        assert_eq!(result_title("update-check", Some("current")), "current");
        assert_eq!(
            result_title("proxy-socat", Some("Switched: the proxy is now tor-socat, and DNS is answering.")),
            "Switched: the proxy is now tor-socat, and DNS is answering."
        );
        // Otherwise, and for a last line that is not the answer: the label.
        assert_eq!(result_title("restart", Some("done")), "Restart the stack: finished");
        assert_eq!(result_title("bridges-on", Some("fake nice-dns: done")), "Turn bridges on: finished");
        assert_eq!(result_title("update-check", None), "Check for an update: finished");
        assert_eq!(failed_title("proxy-socat"), "Switch the proxy to socat did not finish");
    }

    #[test]
    fn bar_elapsed_time_in_words() {
        assert_eq!(elapsed_text(0), "0 s");
        assert_eq!(elapsed_text(59), "59 s");
        assert_eq!(elapsed_text(60), "1 min");
        assert_eq!(elapsed_text(168), "2 min 48 s");
        assert_eq!(elapsed_text(3600), "1 h");
        assert_eq!(elapsed_text(3900), "1 h 5 min");
    }
}
