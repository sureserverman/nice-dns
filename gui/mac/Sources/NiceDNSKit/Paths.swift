// Where the GUI finds the commands it runs, and the environment it runs them
// in. AppKit-free, so KitCheck tests it.
import Foundation

public enum CommandPaths {
    /// The installer's home for the commands: `~/.local/bin` (lib/install.sh
    /// `_nd_inst_command_dir`).
    public static func primary(_ name: String, home: String) -> String {
        (home as NSString).appendingPathComponent(".local/bin/\(name)")
    }

    /// The fallback the installer uses when `~/.local/bin` cannot hold them:
    /// `${XDG_STATE_HOME:-~/.local/state}/nice-dns-health/bin`.
    public static func fallback(_ name: String, home: String, xdgStateHome: String?) -> String {
        let state: String
        if let s = xdgStateHome, !s.isEmpty { state = s } else { state = (home as NSString).appendingPathComponent(".local/state") }
        return (state as NSString).appendingPathComponent("nice-dns-health/bin/\(name)")
    }

    /// The command `name` the GUI runs: the first on `PATH`, as a terminal
    /// would find it, else where the installer put it. An app opened from
    /// Finder has no `~/.local/bin` on its `PATH`, so the second step is the
    /// usual one there. The error names the installer's primary path.
    public static func resolve(_ name: String, environment env: [String: String]) throws -> String {
        if let found = searchPath(name, env["PATH"] ?? "") { return found }
        let home = env["HOME"] ?? NSHomeDirectory()
        let p = primary(name, home: home)
        if isExecutable(p) { return p }
        let f = fallback(name, home: home, xdgStateHome: env["XDG_STATE_HOME"])
        if isExecutable(f) { return f }
        throw CommandNotFound(path: p)
    }

    /// The first executable `name` in a `PATH` value; empty and relative
    /// entries are skipped, never read as the current directory.
    public static func searchPath(_ name: String, _ path: String) -> String? {
        for dir in path.split(separator: ":").map(String.init) where dir.hasPrefix("/") {
            let p = (dir as NSString).appendingPathComponent(name)
            if isExecutable(p) { return p }
        }
        return nil
    }

    /// The environment the commands run in: the app's own, with the
    /// directories the stack's commands need added at the end of `PATH` when
    /// missing — `~/.local/bin` (nice-dns, nice-dns-health), `/opt/homebrew/bin`
    /// and `/usr/local/bin` (Apple's `container` CLI and Homebrew tools). An
    /// app opened from Finder starts with only `/usr/bin:/bin:/usr/sbin:/sbin`.
    public static func childEnvironment(_ env: [String: String]) -> [String: String] {
        var out = env
        let home = env["HOME"] ?? NSHomeDirectory()
        var dirs = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for d in [(home as NSString).appendingPathComponent(".local/bin"), "/opt/homebrew/bin", "/usr/local/bin"] where !dirs.contains(d) {
            dirs.append(d)
        }
        out["PATH"] = dirs.joined(separator: ":")
        return out
    }

    /// The status command: `<nice-dns> status --tsv`. `NICE_DNS_GUI_STATUS_CMD`,
    /// when set, replaces it, split on whitespace: for tests and proofs only.
    public static func statusArgv(environment env: [String: String]) throws -> [String] {
        if let cmd = env["NICE_DNS_GUI_STATUS_CMD"] {
            return cmd.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
        return [try resolve("nice-dns", environment: env), "status", "--tsv"]
    }

    /// Whether the installer's kept source is there, so the Install button can
    /// work (`~/.local/share/nice-dns/source`, with its macOS installer).
    public static func keptSourceExists(home: String) -> Bool {
        FileManager.default.fileExists(atPath: (home as NSString).appendingPathComponent(".local/share/nice-dns/source/install-mac.sh"))
    }

    static func isExecutable(_ p: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && !dir.boolValue
            && FileManager.default.isExecutableFile(atPath: p)
    }
}
