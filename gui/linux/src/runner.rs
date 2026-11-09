//! Run a command without blocking the caller, delivering its output line by
//! line on a channel. GTK-free, so it tests headless.

use std::fmt;
use std::fs;
use std::io::{self, BufRead, BufReader, Read};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stream {
    Stdout,
    Stderr,
}

/// How the command ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Exit {
    Code(i32),
    Signal(i32),
}

impl fmt::Display for Exit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Exit::Code(c) => write!(f, "exit {c}"),
            Exit::Signal(s) => write!(f, "killed by signal {s}"),
        }
    }
}

/// What the channel carries: lines in order within each stream, then exactly
/// one `Exit` (or `Failed` when waiting on the child failed), last.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Line(Stream, String),
    Exit(Exit),
    Failed(String),
}

/// Start `argv[0]` with `argv[1..]`, stdin closed. Returns at once; a program
/// that cannot be started is an `Err`, never a panic.
pub fn spawn<S: AsRef<str>>(argv: &[S]) -> io::Result<Receiver<Event>> {
    let (program, args) = argv
        .split_first()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "empty command"))?;
    let mut child = Command::new(program.as_ref())
        .args(args.iter().map(AsRef::as_ref))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| io::Error::new(e.kind(), format!("{}: {e}", program.as_ref())))?;

    let (tx, rx) = mpsc::channel();
    let out = child.stdout.take().map(|p| pump(p, Stream::Stdout, tx.clone()));
    let err = child.stderr.take().map(|p| pump(p, Stream::Stderr, tx.clone()));
    thread::spawn(move || {
        // Every line is sent before the exit event.
        for h in [out, err].into_iter().flatten() {
            let _ = h.join();
        }
        let ev = match child.wait() {
            Ok(st) => match (st.code(), st.signal()) {
                (Some(c), _) => Event::Exit(Exit::Code(c)),
                (None, Some(s)) => Event::Exit(Exit::Signal(s)),
                (None, None) => Event::Failed("no exit code and no signal".into()),
            },
            Err(e) => Event::Failed(format!("wait: {e}")),
        };
        let _ = tx.send(ev);
    });
    Ok(rx)
}

fn pump<R: Read + Send + 'static>(pipe: R, stream: Stream, tx: Sender<Event>) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut r = BufReader::new(pipe);
        let mut buf = Vec::new();
        loop {
            buf.clear();
            match r.read_until(b'\n', &mut buf) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    if buf.last() == Some(&b'\n') {
                        buf.pop();
                    }
                    let line = String::from_utf8_lossy(&buf).into_owned();
                    if tx.send(Event::Line(stream, line)).is_err() {
                        break;
                    }
                }
            }
        }
    })
}

/// Neither place the installer publishes a command holds it; `primary` is the
/// path the GUI names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotFound {
    pub primary: PathBuf,
}

impl fmt::Display for NotFound {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} not found", self.primary.display())
    }
}

impl std::error::Error for NotFound {}

fn is_executable(p: &Path) -> bool {
    fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Where the installer put the command `name`: `~/.local/bin/<name>`, else
/// `${XDG_STATE_HOME:-~/.local/state}/nice-dns-health/bin/<name>` (lib/install.sh
/// `_nd_inst_command_dir` / `_nd_inst_command_fallback_dir`, health/nice-dns-health
/// `pick_installed_bin`).
pub fn resolve_installed(name: &str) -> Result<PathBuf, NotFound> {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let state = std::env::var_os("XDG_STATE_HOME").map(PathBuf::from);
    resolve_installed_in(name, &home, state.as_deref())
}

/// [`resolve_installed`] with HOME and XDG_STATE_HOME given; an empty
/// XDG_STATE_HOME counts as unset, as `${XDG_STATE_HOME:-...}` does.
pub fn resolve_installed_in(name: &str, home: &Path, xdg_state_home: Option<&Path>) -> Result<PathBuf, NotFound> {
    let primary = home.join(".local/bin").join(name);
    if is_executable(&primary) {
        return Ok(primary);
    }
    let state = match xdg_state_home {
        Some(s) if !s.as_os_str().is_empty() => s.to_path_buf(),
        _ => home.join(".local/state"),
    };
    let fallback = state.join("nice-dns-health/bin").join(name);
    if is_executable(&fallback) {
        return Ok(fallback);
    }
    Err(NotFound { primary })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn collect(rx: Receiver<Event>) -> Vec<Event> {
        let mut v = Vec::new();
        loop {
            let ev = rx.recv_timeout(Duration::from_secs(20)).expect("event within 20 s");
            let last = !matches!(ev, Event::Line(..));
            v.push(ev);
            if last {
                return v;
            }
        }
    }

    fn lines_of(evs: &[Event], s: Stream) -> Vec<String> {
        evs.iter()
            .filter_map(|e| match e {
                Event::Line(st, l) if *st == s => Some(l.clone()),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn runner_delivers_lines_in_order_and_the_exit_code() {
        let rx = spawn(&[
            "sh",
            "-c",
            "echo one; echo err-a >&2; echo two; echo err-b >&2; printf 'three'; exit 3",
        ])
        .unwrap();
        let evs = collect(rx);
        assert_eq!(lines_of(&evs, Stream::Stdout), ["one", "two", "three"]);
        assert_eq!(lines_of(&evs, Stream::Stderr), ["err-a", "err-b"]);
        assert_eq!(evs.last(), Some(&Event::Exit(Exit::Code(3))));
        assert_eq!(evs.iter().filter(|e| !matches!(e, Event::Line(..))).count(), 1);
    }

    #[test]
    fn runner_reports_a_signal() {
        let evs = collect(spawn(&["sh", "-c", "kill -TERM $$"]).unwrap());
        assert_eq!(evs.last(), Some(&Event::Exit(Exit::Signal(15))));
    }

    #[test]
    fn runner_does_not_block_the_caller() {
        let t = std::time::Instant::now();
        let rx = spawn(&["sh", "-c", "sleep 2; echo late"]).unwrap();
        assert!(t.elapsed() < Duration::from_secs(1));
        assert!(rx.try_recv().is_err());
        assert_eq!(collect(rx).last(), Some(&Event::Exit(Exit::Code(0))));
    }

    #[test]
    fn runner_missing_program_is_an_error() {
        let e = spawn(&["/nonexistent/nice-dns-gui-test-program"]).unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::NotFound);
        assert!(e.to_string().contains("/nonexistent/nice-dns-gui-test-program"));
        let empty: [&str; 0] = [];
        assert_eq!(spawn(&empty).unwrap_err().kind(), io::ErrorKind::InvalidInput);
    }

    fn put_exe(p: &Path, mode: u32) {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, "#!/bin/sh\n").unwrap();
        fs::set_permissions(p, fs::Permissions::from_mode(mode)).unwrap();
    }

    fn temp_root(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("nice-dns-gui-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn runner_resolver_prefers_local_bin_and_falls_back() {
        let root = temp_root("resolve");
        let home = root.join("home");
        let state = root.join("state");
        let primary = home.join(".local/bin/nice-dns");
        let fallback = state.join("nice-dns-health/bin/nice-dns");

        // Neither: the error names the primary path.
        assert_eq!(
            resolve_installed_in("nice-dns", &home, Some(&state)),
            Err(NotFound { primary: primary.clone() })
        );
        // Only the fallback (under XDG_STATE_HOME).
        put_exe(&fallback, 0o755);
        assert_eq!(resolve_installed_in("nice-dns", &home, Some(&state)), Ok(fallback.clone()));
        // A primary that is not executable does not count.
        put_exe(&primary, 0o644);
        assert_eq!(resolve_installed_in("nice-dns", &home, Some(&state)), Ok(fallback.clone()));
        // An executable primary wins.
        fs::set_permissions(&primary, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(resolve_installed_in("nice-dns", &home, Some(&state)), Ok(primary.clone()));

        // XDG_STATE_HOME unset or empty: ~/.local/state.
        let default_fb = home.join(".local/state/nice-dns-health/bin/nice-dns-health");
        put_exe(&default_fb, 0o755);
        assert_eq!(resolve_installed_in("nice-dns-health", &home, None), Ok(default_fb.clone()));
        assert_eq!(resolve_installed_in("nice-dns-health", &home, Some(Path::new(""))), Ok(default_fb));
        let _ = fs::remove_dir_all(&root);
    }
}
