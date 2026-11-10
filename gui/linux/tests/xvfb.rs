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
