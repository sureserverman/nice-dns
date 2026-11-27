//! Compiles `resources/` (the pack's symbolic icons) into a GResource that
//! `src/icons.rs` registers at start. `glib-compile-resources` comes with
//! libglib2.0-dev-bin, which libgtk-4-dev already pulls in.

use std::path::PathBuf;
use std::process::Command;

fn main() {
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("cargo sets OUT_DIR"));
    println!("cargo:rerun-if-changed=resources");
    let status = Command::new("glib-compile-resources")
        .args(["--sourcedir=resources", "--target"])
        .arg(out.join("nice-dns.gresource"))
        .arg("resources/nice-dns.gresource.xml")
        .status()
        .expect("glib-compile-resources is needed to build (apt-get install libglib2.0-dev-bin)");
    assert!(status.success(), "glib-compile-resources failed");
}
