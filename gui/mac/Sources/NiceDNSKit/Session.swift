// What the window and the hooks share: the line said under an action's
// output, the menu-bar glyph, one action run streamed into a pane, and the
// one line `--check` prints. AppKit-free, so KitCheck tests it.
import Foundation

/// What the command prints when root work could not go ahead (lib/root.sh):
/// the authorisation was dismissed (126), or nothing could authorise it (127).
public let authorisationCancelled = "authorisation cancelled"
public let notAuthorised = "not authorised"

/// The one line said under an action's output. `update-check` answers 0 and
/// 10 as the contract does; `update` 11 as well (docs/cli-contract.md).
public func outcome(id: String, end: CommandEvent, lines: [String]) -> String {
    let saw = { (needle: String) in lines.contains { $0.contains(needle) } }
    switch end {
    case .exit(.code(let c)):
        if c == 126 || (c != 0 && saw(authorisationCancelled)) { return "\(authorisationCancelled) (exit \(c))" }
        if c == 127 || (c != 0 && saw(notAuthorised)) { return "\(notAuthorised) (exit \(c))" }
        switch (id, c) {
        case ("update-check", 0): return "up to date (exit 0)"
        case ("update-check", 10): return "a different version is available (exit 10)"
        case ("update-check", 1): return "unknown (exit 1)"
        case ("update", 11): return "installed, but the check afterwards did not say current (exit 11)"
        case (_, 0): return "finished (exit 0)"
        default: return "failed (exit \(c))"
        }
    case .exit(.signal(let s)): return "stopped by signal \(s)"
    case .failed(let m): return "could not run: \(m)"
    case .line: return "still running"
    }
}

/// Whether an action's end counts as success: exit 0, 10 for `update-check`
/// (a different version is available) and 11 for `update` (installed).
public func succeeded(id: String, end: CommandEvent) -> Bool {
    switch end {
    case .exit(.code(0)): return true
    case .exit(.code(10)): return id == "update-check"
    case .exit(.code(11)): return id == "update"
    default: return false
    }
}

/// The menu-bar glyph's colour.
public enum Glyph: String, Equatable {
    case grey, green, amber, red

    /// Grey: not installed. Red: the status cannot be shown, the controller
    /// says FAIL, or an observation is unhealthy. Amber: the controller is
    /// stale, its verdict is not OK, an observation is indeterminate, or a
    /// file status reads cannot be read. Green otherwise.
    public static func of(_ view: StatusView) -> Glyph {
        switch view {
        case .notInstalled: return .grey
        case .error: return .red
        case .unreadable(let s): return of(s) == .red ? .red : .amber
        case .installed(let s): return of(s)
        }
    }

    static func of(_ s: Status) -> Glyph {
        let verdict = s.controller.verdict ?? "unknown"
        if verdict.hasPrefix("FAIL") || s.obs.contains(where: { $0.verdict == "unhealthy" }) { return .red }
        if s.controller.stale != .no || verdict != "OK" || s.obs.contains(where: { $0.verdict != "healthy" }) { return .amber }
        return .green
    }
}

/// One action, run as a subprocess and streamed into a pane: the command
/// line first, then its lines, then the outcome. The window and
/// `--run-action` both run actions through it.
public final class ActionRun {
    public let id: String
    public private(set) var paneLines: [String] = []
    public private(set) var outputLines: [String] = []
    public private(set) var end: CommandEvent?
    private var running: RunningCommand?

    /// How many output lines are kept for `outcome`; the pane keeps all.
    static let keep = 400

    public init(id: String) { self.id = id }

    /// The argv for action `id`, its program found in `environment`. `nil`
    /// for an action that runs no command (handled in the app).
    public static func argv(_ id: String, choices: Choices?, environment: [String: String]) throws -> [String]? {
        try Actions.argv(id, choices: choices) { try CommandPaths.resolve($0, environment: environment) }
    }

    /// Start it. `onChange` is called on `queue` after every pane line, and
    /// once more with `end` set. A command that cannot be found or started
    /// ends at once with `.failed`.
    public func start(choices: Choices? = nil, environment: [String: String], queue: DispatchQueue,
                      onChange: @escaping (ActionRun) -> Void) {
        let label = Actions.lookup(id)?.label ?? id
        let argv: [String]
        do {
            guard let v = try ActionRun.argv(id, choices: choices, environment: environment) else {
                return finish(.failed("'\(id)' runs no command"), queue, onChange, later: true)
            }
            argv = v
        } catch {
            paneLines.append(label)
            return finish(.failed("\(error)"), queue, onChange, later: true)
        }
        paneLines.append("$ " + argv.joined(separator: " "))
        do {
            running = try CommandRunner.spawn(argv, environment: CommandPaths.childEnvironment(environment), queue: queue) { [self] ev in
                switch ev {
                case .line(_, let text):
                    // A progress bar redraws with \r: keep the last state of the line.
                    let shown = text.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? ""
                    outputLines.append(shown)
                    if outputLines.count > ActionRun.keep { outputLines.removeFirst() }
                    paneLines.append(shown)
                    onChange(self)
                default:
                    finish(ev, queue, onChange, later: false)
                }
            }
        } catch {
            finish(.failed("\(error)"), queue, onChange, later: true)
        }
    }

    public func terminate() { running?.terminate() }

    /// The line said under the output, once ended.
    public var said: String? { end.map { outcome(id: id, end: $0, lines: outputLines) } }

    /// The exit status `--run-action` gives: the command's, 128 + a signal,
    /// 1 when it could not run.
    public var exitStatus: Int32 {
        switch end {
        case .exit(.code(let c))?: return c
        case .exit(.signal(let s))?: return 128 + s
        default: return 1
        }
    }

    public var paneText: String { paneLines.map { $0 + "\n" }.joined() }

    /// `later`: called on the caller's thread before anything ran, so the
    /// end is delivered on `queue` like every other event.
    private func finish(_ ev: CommandEvent, _ queue: DispatchQueue, _ onChange: @escaping (ActionRun) -> Void, later: Bool) {
        let deliver = { [self] in
            if case .failed(let m) = ev { paneLines.append(m) }
            end = ev
            paneLines.append(outcome(id: id, end: ev, lines: outputLines))
            running = nil
            onChange(self)
        }
        if later { queue.async(execute: deliver) } else { deliver() }
    }
}

/// Run the status command once: the exit code `--check` gives and the one
/// line it prints.
public func statusCheck(environment env: [String: String]) -> (Int32, String) {
    let argv: [String]
    do {
        argv = try CommandPaths.statusArgv(environment: env)
    } catch let nf as CommandNotFound {
        return (1, "nice-dns command not found: looked for \(nf.path)")
    } catch {
        return (2, "nice-dns-gui: \(error)")
    }
    guard !argv.isEmpty else { return (2, "nice-dns-gui: the status command is empty") }
    let r: CommandRunner.Collected
    do {
        r = try CommandRunner.collect(argv, environment: CommandPaths.childEnvironment(env))
    } catch {
        return (2, "nice-dns-gui: cannot run \(argv[0]): \(error)")
    }
    let code: Int32?
    if case .code(let c)? = r.exit { code = c } else { code = nil }
    switch classify(exit: code, stdout: r.stdout.map { $0 + "\n" }.joined()) {
    case .installed(let s):
        return (0, "installed: generation \(s.install.generation ?? "unknown"); controller \(s.controller.verdict ?? "unknown"), \(s.controller.stale.map { "\($0)" } ?? "unknown")")
    case .notInstalled(let hint, let unreadable):
        var line = "not installed"
        if !unreadable.isEmpty { line += "; unreadable: " + unreadable.map { "\($0.group): \($0.reason)" }.joined(separator: "; ") }
        if let h = hint { line += "; install with: \(h)" }
        return (unreadable.isEmpty ? 1 : 2, line)
    case .unreadable(let s):
        return (2, "unreadable: " + s.unreadable.map { "\($0.group): \($0.reason)" }.joined(separator: "; "))
    case .error(let m):
        if let l = r.stderr.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return (2, "error: \(m) (\(l.trimmingCharacters(in: .whitespaces)))")
        }
        return (2, "error: \(m)")
    }
}
