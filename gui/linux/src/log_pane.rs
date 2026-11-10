//! The log pane (Task 1.3): the running action's own output, line by line,
//! then what its exit means. The output stays until the next action starts.

use gtk4 as gtk;
use gtk::prelude::*;

use crate::runner::{Event, Exit, Stream};

/// What the command printed when root work could not go ahead (lib/root.sh):
/// pkexec's dialog was dismissed (126), or nothing could authorise it (127).
pub const CANCELLED: &str = "authorisation cancelled";
pub const NOT_AUTHORISED: &str = "not authorised";

/// How many of the last output lines are kept for `outcome`.
const KEEP_LINES: usize = 400;

/// The one line said under an action's output. `id` is the action's id:
/// `update-check` answers 0 and 10 as the contract does.
pub fn outcome(id: &str, end: &Event, lines: &[String]) -> String {
    let saw = |needle: &str| lines.iter().any(|l| l.contains(needle));
    match end {
        Event::Exit(Exit::Code(c)) => {
            let c = *c;
            if c == 126 || (c != 0 && saw(CANCELLED)) {
                format!("{CANCELLED} (exit {c})")
            } else if c == 127 || (c != 0 && saw(NOT_AUTHORISED)) {
                format!("{NOT_AUTHORISED} (exit {c})")
            } else if id == "update-check" && c == 0 {
                "up to date (exit 0)".into()
            } else if id == "update-check" && c == 10 {
                "a different version is available (exit 10)".into()
            } else if id == "update-check" && c == 1 {
                "unknown (exit 1)".into()
            } else if id == "update" && c == 11 {
                "installed, but the check afterwards did not say current (exit 11)".into()
            } else if c == 0 {
                "finished (exit 0)".into()
            } else {
                format!("failed (exit {c})")
            }
        }
        Event::Exit(Exit::Signal(s)) => format!("stopped by signal {s}"),
        Event::Failed(msg) => format!("could not run: {msg}"),
        Event::Line(..) => "still running".into(),
    }
}

/// Whether an action's end counts as success: exit 0, and 10 for
/// `update-check` (a different version is available).
pub fn succeeded(id: &str, end: &Event) -> bool {
    matches!(end, Event::Exit(Exit::Code(0)))
        || (id == "update-check" && matches!(end, Event::Exit(Exit::Code(10))))
        // The update was installed and the stack runs it (the contract's 11).
        || (id == "update" && matches!(end, Event::Exit(Exit::Code(11))))
}

pub struct LogPane {
    pub widget: gtk::Box,
    title: gtk::Label,
    result: gtk::Label,
    buffer: gtk::TextBuffer,
    view: gtk::TextView,
    lines: std::cell::RefCell<Vec<String>>,
}

impl LogPane {
    pub fn new() -> LogPane {
        let title = gtk::Label::builder().xalign(0.0).label("No action run yet").build();
        title.add_css_class("heading");
        let result = gtk::Label::builder().xalign(1.0).hexpand(true).selectable(true).build();
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        head.set_margin_start(12);
        head.set_margin_end(12);
        head.set_margin_top(6);
        head.set_margin_bottom(6);
        head.append(&title);
        head.append(&result);

        let buffer = gtk::TextBuffer::new(None);
        buffer.create_tag(Some("stderr"), &[("foreground", &"#c0a050")]);
        buffer.create_tag(Some("auth"), &[("foreground", &"#e05050"), ("weight", &700i32)]);
        let view = gtk::TextView::builder()
            .buffer(&buffer)
            .editable(false)
            .cursor_visible(false)
            .monospace(true)
            .wrap_mode(gtk::WrapMode::WordChar)
            .left_margin(12)
            .right_margin(12)
            .top_margin(6)
            .bottom_margin(6)
            .build();
        let scroller = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .min_content_height(160)
            .child(&view)
            .build();

        let widget = gtk::Box::new(gtk::Orientation::Vertical, 0);
        widget.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
        widget.append(&head);
        widget.append(&scroller);
        LogPane { widget, title, result, buffer, view, lines: Default::default() }
    }

    /// A new action: the old output goes, the command line is shown.
    pub fn start(&self, label: &str, argv: &[String]) {
        self.lines.borrow_mut().clear();
        self.buffer.set_text("");
        self.title.set_text(label);
        self.result.set_text("running…");
        self.result.remove_css_class("error");
        self.result.remove_css_class("success");
        self.append(&format!("$ {}", argv.join(" ")), None);
    }

    pub fn line(&self, stream: Stream, text: &str) {
        // A progress bar redraws with \r: show the last state of the line.
        let text = text.rsplit('\r').find(|t| !t.is_empty()).unwrap_or("");
        let tag = if text.contains(CANCELLED) || text.contains(NOT_AUTHORISED) {
            Some("auth")
        } else if stream == Stream::Stderr {
            Some("stderr")
        } else {
            None
        };
        let mut lines = self.lines.borrow_mut();
        // The end of the output is what `outcome` and the update offer read;
        // the pane itself keeps everything.
        if lines.len() >= KEEP_LINES {
            lines.remove(0);
        }
        lines.push(text.to_string());
        drop(lines);
        self.append(text, tag);
    }

    /// The last output line starting with `prefix`.
    pub fn last_line_with_prefix(&self, prefix: &str) -> Option<String> {
        self.lines.borrow().iter().rev().find(|l| l.starts_with(prefix)).cloned()
    }

    pub fn scroll_to_end(&self) {
        let mark = self.buffer.create_mark(None, &self.buffer.end_iter(), false);
        self.view.scroll_mark_onscreen(&mark);
        self.buffer.delete_mark(&mark);
    }

    /// The end of the action; returns the line shown.
    pub fn finish(&self, id: &str, end: &Event) -> String {
        let said = outcome(id, end, &self.lines.borrow());
        self.result.set_text(&said);
        self.result.add_css_class(if succeeded(id, end) { "success" } else { "error" });
        self.append(&said, if succeeded(id, end) { None } else { Some("auth") });
        said
    }

    /// Everything in the pane, as shown.
    pub fn text(&self) -> String {
        let (a, b) = self.buffer.bounds();
        self.buffer.text(&a, &b, false).to_string()
    }

    fn append(&self, text: &str, tag: Option<&str>) {
        let mut end = self.buffer.end_iter();
        match tag {
            Some(t) => self.buffer.insert_with_tags_by_name(&mut end, &format!("{text}\n"), &[t]),
            None => self.buffer.insert(&mut end, &format!("{text}\n")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn code(c: i32) -> Event {
        Event::Exit(Exit::Code(c))
    }

    #[test]
    fn actions_outcome_names_a_dismissed_dialog_and_a_refusal() {
        assert_eq!(outcome("restart", &code(126), &[]), "authorisation cancelled (exit 126)");
        assert_eq!(outcome("restart", &code(127), &[]), "not authorised (exit 127)");
        // The command's own exit with lib/root.sh's line on stderr.
        let said = vec!["nice-dns: authorisation cancelled".to_string()];
        assert_eq!(outcome("reinstall", &code(1), &said), "authorisation cancelled (exit 1)");
        let said = vec!["nice-dns: not authorised (or no polkit authentication agent could ask for a password)".into()];
        assert_eq!(outcome("uninstall", &code(3), &said), "not authorised (exit 3)");
    }

    #[test]
    fn actions_outcome_reads_update_check_as_the_contract_does() {
        assert_eq!(outcome("update-check", &code(0), &[]), "up to date (exit 0)");
        assert_eq!(outcome("update-check", &code(10), &[]), "a different version is available (exit 10)");
        assert!(succeeded("update-check", &code(10)));
        assert!(!succeeded("restart", &code(10)));
        assert_eq!(outcome("restart", &code(10), &[]), "failed (exit 10)");
        assert_eq!(outcome("update-check", &code(1), &[]), "unknown (exit 1)");
        assert!(outcome("update", &code(11), &[]).starts_with("installed, but"));
        assert!(succeeded("update", &code(11)));
        assert!(!succeeded("update-check", &code(11)));
    }

    #[test]
    fn actions_outcome_plain_exits() {
        assert_eq!(outcome("restart", &code(0), &[]), "finished (exit 0)");
        assert_eq!(outcome("restart", &code(3), &[]), "failed (exit 3)");
        assert_eq!(outcome("restart", &Event::Exit(Exit::Signal(9)), &[]), "stopped by signal 9");
        assert!(outcome("restart", &Event::Failed("x".into()), &[]).starts_with("could not run"));
    }
}
