//! The window under Xvfb: `--screenshot` renders each fixture into a PNG.
//! Needs `xvfb-run` (the `xvfb` package); without it the test fails, so a
//! missing tool is never read as a pass.

use std::path::{Path, PathBuf};
use std::process::Command;

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../share/fixtures")
}

fn screenshot(fixture: &str, exit: i32) -> (bool, u64, String) {
    let dir = std::env::temp_dir().join(format!("nice-dns-gui-xvfb-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let png = dir.join(format!("{fixture}.png"));
    let _ = std::fs::remove_file(&png);
    let status_cmd = format!("{} {} {exit}", fixtures().join("fake-status.sh").display(), fixtures().join(fixture).display());
    let out = Command::new("xvfb-run")
        .args(["-a", env!("CARGO_BIN_EXE_nice-dns-gui"), "--screenshot"])
        .arg(&png)
        .env("NICE_DNS_GUI_STATUS_CMD", status_cmd)
        .env("GSK_RENDERER", "cairo")
        .output()
        .expect("xvfb-run is not installed (apt-get install xvfb)");
    let size = std::fs::metadata(&png).map_or(0, |m| m.len());
    (out.status.success(), size, String::from_utf8_lossy(&out.stderr).into_owned())
}

#[test]
fn window_screenshot_under_xvfb_writes_a_png_for_every_fixture() {
    for (fixture, exit) in [
        ("status-installed.tsv", 0),
        ("status-stale.tsv", 0),
        ("status-update-available.tsv", 0),
        ("status-not-installed.tsv", 1),
    ] {
        let (ok, size, stderr) = screenshot(fixture, exit);
        assert!(ok, "{fixture}: --screenshot failed: {stderr}");
        assert!(size > 10_000, "{fixture}: PNG is {size} bytes: {stderr}");
    }
}

/// A plain launch (no hook) keeps the window alive: its status is read again
/// every few seconds. The hooks each hold the window in a closure, so only
/// this test sees a launch whose window is dropped after the first read.
#[test]
fn window_plain_launch_keeps_reading_the_status() {
    let dir = std::env::temp_dir().join(format!("nice-dns-gui-launch-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let count = dir.join("reads");
    let _ = std::fs::remove_file(&count);
    let reader = dir.join("counting-status.sh");
    std::fs::write(
        &reader,
        format!(
            "#!/bin/sh\necho read >> {}\nexec {} {} 0\n",
            count.display(),
            fixtures().join("fake-status.sh").display(),
            fixtures().join("status-installed.tsv").display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&reader, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    // No session bus, so the unique application never hands its work to a
    // window already open on this desktop; `timeout` ends it after 13 s.
    let out = Command::new("xvfb-run")
        .args(["-a", "timeout", "13", env!("CARGO_BIN_EXE_nice-dns-gui")])
        .env("NICE_DNS_GUI_STATUS_CMD", reader.to_string_lossy().as_ref())
        .env("DBUS_SESSION_BUS_ADDRESS", format!("unix:path={}", dir.join("no-bus").display()))
        .env("GSK_RENDERER", "cairo")
        .output()
        .expect("xvfb-run is not installed (apt-get install xvfb)");
    let reads = std::fs::read_to_string(&count).map_or(0, |t| t.lines().count());
    let _ = std::fs::remove_dir_all(&dir);
    // Read at 0 s, 5 s and 10 s: three reads, or the window stopped after one.
    assert!(reads >= 3, "the status was read {reads} time(s) in 13 s: {}", String::from_utf8_lossy(&out.stderr));
}

// ─────────── the Proxy and Pi-hole selectors, through --probe ───────────

const INSTALLED: &str = include_str!("../../share/fixtures/status-installed.tsv");

fn fakebin() -> PathBuf {
    fixtures().join("fakebin")
}

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

fn field<'a>(line: &'a str, key: &str) -> &'a str {
    let p = format!("{key}=");
    line.split(' ').find_map(|w| w.strip_prefix(&p)).unwrap_or_else(|| panic!("no {key} in {line}"))
}

/// `--probe <id>` under Xvfb with the fake `nice-dns` (exiting `fake_exit`).
/// `status` reads `before` until the fake has been asked to `switch`, then
/// `after`; `answer` is what the probe answers the question (`switch` or
/// `cancel`).
fn probe_selector(tag: &str, id: &str, fake_exit: i32, answer: &str, before: &str, after: &str) -> Probe {
    let home = std::env::temp_dir().join(format!("nice-dns-gui-sel-{}-{tag}", std::process::id()));
    std::fs::create_dir_all(&home).unwrap();
    let record = home.join("record");
    let _ = std::fs::remove_file(&record);
    std::fs::write(home.join("before.tsv"), before).unwrap();
    std::fs::write(home.join("after.tsv"), after).unwrap();
    let status = home.join("status.sh");
    std::fs::write(
        &status,
        format!(
            "#!/bin/sh\nif grep -q '^switch ' {r} 2>/dev/null; then cat {a}; else cat {b}; fi\n",
            r = record.display(),
            a = home.join("after.tsv").display(),
            b = home.join("before.tsv").display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&status, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let out = Command::new("xvfb-run")
        .args(["-a", env!("CARGO_BIN_EXE_nice-dns-gui"), "--probe", id])
        .env("PATH", format!("{}:/usr/bin:/bin", fakebin().display()))
        .env("HOME", &home)
        .env("XDG_STATE_HOME", home.join("state"))
        .env("NICE_DNS_GUI_STATUS_CMD", status.to_string_lossy().as_ref())
        .env("NICE_DNS_GUI_PROBE_ANSWER", answer)
        .env("NICE_DNS_FAKE_RECORD", &record)
        .env("NICE_DNS_FAKE_EXIT", fake_exit.to_string())
        .env("GSK_RENDERER", "cairo")
        .output()
        .expect("xvfb-run is not installed (apt-get install xvfb)");
    let record = std::fs::read_to_string(&record).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&home);
    Probe {
        code: out.status.code(),
        out: format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr)),
        record,
    }
}

fn with_proxy(v: &str) -> String {
    INSTALLED.replacen("install\tvariant\tsocat", &format!("install\tvariant\t{v}"), 1)
}

const QUESTION_TAIL: &str = "The stack is reinstalled from the kept source. This takes a few minutes and DNS stops briefly.";

#[test]
fn selectors_the_installed_fixture_shows_both_with_the_status_values() {
    let p = probe_selector("render", "restart", 0, "switch", INSTALLED, INSTALLED);
    assert_eq!(p.code, Some(0), "{}", p.out);
    let before = p.at("before");
    assert_eq!(field(before, "proxy"), "socat", "{before}");
    assert_eq!(field(before, "pihole"), "standard", "{before}");
    assert_eq!(field(before, "disabled"), "0", "both selectors are enabled: {before}");
    // Counted among the controls: the 14 buttons-and-switch of the table plus two.
    assert!(field(before, "controls").parse::<u32>().unwrap() >= 12, "{before}");
}

#[test]
fn selectors_picking_the_other_proxy_asks_then_runs_and_the_next_read_confirms() {
    let p = probe_selector("socat", "proxy-socat", 0, "switch", &with_proxy("haproxy"), INSTALLED);
    assert_eq!(p.code, Some(0), "{}", p.out);
    assert_eq!(field(p.at("before"), "proxy"), "haproxy", "{}", p.out);
    // The question, verbatim, before anything ran.
    let q = p.at("question");
    assert_eq!(field(q, "dialog"), "Switch_the_proxy_to_socat?", "{q}");
    assert!(q.ends_with(&format!("body={QUESTION_TAIL}")), "{q}");
    // Running: the selector shows the new value; every control is disabled, the selectors too.
    let during = p.at("during");
    assert_eq!(field(during, "proxy"), "socat", "{during}");
    assert_eq!(field(during, "disabled"), field(during, "controls"), "{during}");
    // The next status read says socat: that is what stays.
    let after = p.at("after");
    assert_eq!(field(after, "proxy"), "socat", "{after}");
    assert_eq!(field(after, "disabled"), "0", "{after}");
    assert_eq!(p.record, "switch proxy socat\n", "{}", p.out);
    assert!(p.out.contains("pane: finished (exit 0)"), "{}", p.out);
}

#[test]
fn selectors_the_pihole_question_names_the_chosen_value() {
    let p = probe_selector("hardened", "pihole-hardened", 0, "switch", INSTALLED, &INSTALLED.replacen("pihole\tstandard", "pihole\thardened", 1));
    assert_eq!(p.code, Some(0), "{}", p.out);
    let q = p.at("question");
    assert_eq!(field(q, "dialog"), "Switch_Pi-hole_to_hardened?", "{q}");
    assert!(q.ends_with(&format!("body={QUESTION_TAIL}")), "{q}");
    assert_eq!(field(p.at("during"), "pihole"), "hardened", "{}", p.out);
    assert_eq!(field(p.at("after"), "pihole"), "hardened", "{}", p.out);
    assert_eq!(p.record, "switch pihole hardened\n", "{}", p.out);
}

#[test]
fn selectors_not_now_puts_the_selector_back_and_runs_nothing() {
    let p = probe_selector("notnow", "pihole-hardened", 0, "cancel", INSTALLED, INSTALLED);
    assert_eq!(p.code, Some(0), "{}", p.out);
    assert_eq!(field(p.at("question"), "dialog"), "Switch_Pi-hole_to_hardened?", "{}", p.out);
    let during = p.at("during");
    assert_eq!(field(during, "pihole"), "standard", "{during}");
    assert_eq!(field(during, "disabled"), "0", "nothing is running: {during}");
    assert_eq!(field(p.at("after"), "pihole"), "standard", "{}", p.out);
    assert_eq!(p.record, "", "no command ran: {}", p.out);
}

#[test]
fn selectors_a_failed_switch_puts_the_selector_back_and_names_the_exit() {
    let before = with_proxy("haproxy");
    let p = probe_selector("exit3", "proxy-socat", 3, "switch", &before, &before);
    assert_eq!(p.code, Some(0), "{}", p.out);
    assert_eq!(field(p.at("during"), "proxy"), "socat", "{}", p.out);
    assert_eq!(field(p.at("after"), "proxy"), "haproxy", "{}", p.out);
    assert_eq!(field(p.at("after"), "disabled"), "0", "{}", p.out);
    assert!(p.out.contains("pane: failed (exit 3)"), "{}", p.out);
    // The command's stderr is in the log pane.
    assert!(p.at("log").contains("fake nice-dns: a line on stderr"), "{}", p.out);
    let toast = p.at("toast");
    assert!(toast.contains("did not happen") && toast.contains("exit 3"), "{toast}");
}

#[test]
fn selectors_a_root_step_not_authorised_puts_the_selector_back() {
    let before = with_proxy("haproxy");
    let p = probe_selector("exit126", "proxy-socat", 126, "switch", &before, &before);
    assert_eq!(p.code, Some(0), "{}", p.out);
    assert_eq!(field(p.at("after"), "proxy"), "haproxy", "{}", p.out);
    assert!(p.out.contains("pane: authorisation cancelled (exit 126)"), "{}", p.out);
    assert!(p.at("toast").contains("did not happen"), "{}", p.out);
}

#[test]
fn selectors_a_status_that_does_not_name_the_choice_disables_that_selector() {
    // No `install variant` row.
    let no_variant: String = INSTALLED.lines().filter(|l| !l.starts_with("install\tvariant")).map(|l| format!("{l}\n")).collect();
    let p = probe_selector("novariant", "restart", 0, "switch", &no_variant, &no_variant);
    assert_eq!(p.code, Some(0), "{}", p.out);
    let b = p.at("before");
    assert_eq!(field(b, "proxy"), "unknown", "{b}");
    assert_eq!(field(b, "pihole"), "standard", "{b}");
    assert_eq!(field(b, "disabled"), "1", "only the proxy selector is disabled: {b}");
    // A value outside the two.
    let odd = INSTALLED.replacen("install\tpihole\tstandard", "install\tpihole\tparanoid", 1);
    let p = probe_selector("oddflavour", "restart", 0, "switch", &odd, &odd);
    assert_eq!(p.code, Some(0), "{}", p.out);
    let b = p.at("before");
    assert_eq!(field(b, "pihole"), "unknown", "{b}");
    assert_eq!(field(b, "proxy"), "socat", "{b}");
    assert_eq!(field(b, "disabled"), "1", "{b}");
}

/// `--probe <id>` with `NICE_DNS_GUI_PROBE_REDRAW=1`: every status read says
/// a different last controller pass, so every read changes the page, as the
/// clock and each controller pass do on a running machine.
fn probe_redraw(tag: &str, id: &str) -> Probe {
    let home = std::env::temp_dir().join(format!("nice-dns-gui-redraw-{}-{tag}", std::process::id()));
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join("status.tsv"), INSTALLED).unwrap();
    let status = home.join("status.sh");
    std::fs::write(
        &status,
        format!(
            "#!/bin/sh\nn=$(cat {n} 2>/dev/null || echo 0); n=$((n + 1)); echo $n > {n}\n\
             sed \"s/^controller\tlast_pass\t.*/controller\tlast_pass\t$(( $(date +%s) - 3600 * n ))/\" {s}\n",
            n = home.join("reads").display(),
            s = home.join("status.tsv").display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&status, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let out = Command::new("xvfb-run")
        .args(["-a", env!("CARGO_BIN_EXE_nice-dns-gui"), "--probe", id])
        .env("PATH", format!("{}:/usr/bin:/bin", fakebin().display()))
        .env("HOME", &home)
        .env("XDG_STATE_HOME", home.join("state"))
        .env("NICE_DNS_GUI_STATUS_CMD", status.to_string_lossy().as_ref())
        .env("NICE_DNS_GUI_PROBE_REDRAW", "1")
        .env("NICE_DNS_GUI_PROBE_ANSWER", "cancel")
        .env("NICE_DNS_FAKE_RECORD", home.join("record"))
        .env("NICE_DNS_FAKE_EXIT", "0")
        .env("GSK_RENDERER", "cairo")
        .output()
        .expect("xvfb-run is not installed (apt-get install xvfb)");
    let record = std::fs::read_to_string(home.join("record")).unwrap_or_default();
    let reads: u32 = std::fs::read_to_string(home.join("reads")).ok().and_then(|s| s.trim().parse().ok()).unwrap_or(0);
    let _ = std::fs::remove_dir_all(&home);
    Probe {
        code: out.status.code(),
        out: format!("{}{}reads={reads}\n", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr)),
        record,
    }
}

#[test]
fn selectors_a_status_read_leaves_an_open_list_and_the_question_alone() {
    for (tag, id, kind, pick) in [("proxy", "proxy-haproxy", "proxy", "haproxy"), ("pihole", "pihole-hardened", "pihole", "hardened")] {
        let p = probe_redraw(tag, id);
        assert_eq!(p.code, Some(0), "{}", p.out);
        // The reads really happened, so the page really changed under it.
        assert!(p.out.contains("reads=") && !p.out.contains("reads=0") && !p.out.contains("reads=1\n"), "{}", p.out);
        let popup = p.at("popup");
        assert_eq!(field(popup, "opened"), "yes", "the probe could not open the {kind} list, so this run proves nothing: {popup}");
        assert_eq!(field(popup, "same"), "yes", "a read replaced the {kind} selector while its list was open: {popup}");
        assert_eq!(field(popup, "open"), "yes", "a read closed the {kind} list: {popup}");
        let redraw = p.at("redraw");
        assert_eq!(field(redraw, "same"), "yes", "a read replaced the {kind} selector behind the question: {redraw}");
        assert_eq!(field(redraw, kind), pick, "a read snapped the {kind} selector back behind the question: {redraw}");
        assert!(field(redraw, "dialog").starts_with("Switch_"), "{redraw}");
        // Not now put the selector back on the installed value and ran nothing.
        let after = p.at("after");
        assert_eq!(field(after, kind), if kind == "proxy" { "socat" } else { "standard" }, "{after}");
        assert_eq!(p.record.lines().filter(|l| l.starts_with("switch ")).count(), 0, "Not now ran a switch: {}", p.record);
    }
}
