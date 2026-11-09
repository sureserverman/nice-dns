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
