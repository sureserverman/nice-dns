// The app's state: the last status read, the action running and its pane.
// The window and the menu bar both read it; every action goes through `run`.
import AppKit
import Combine
import NiceDNSKit

/// What the window shows.
enum Page: Equatable {
    case loading
    case status(StatusView)
    /// `nice-dns` is nowhere the GUI looks: the path it looked for first.
    case missing(String)
}

/// A question asked before an action runs.
enum Confirm: Equatable, Identifiable {
    case uninstall
    case reinstall(Choices)
    case update(String?)

    var id: String {
        switch self {
        case .uninstall: return "uninstall"
        case .reinstall: return "reinstall"
        case .update: return "update"
        }
    }
}

final class AppModel: ObservableObject {
    @Published private(set) var page: Page = .loading
    @Published private(set) var busy = false
    @Published private(set) var paneTitle = ""
    @Published private(set) var paneText = ""
    @Published private(set) var paneResult = ""
    @Published private(set) var paneOK = true
    /// The bridges switch as the user last set it, until the command ends;
    /// then the status decides again, so a switch that failed goes back.
    @Published private(set) var bridgesPending: Bool?
    @Published var confirm: Confirm?
    @Published var notice: String?

    let environment: [String: String]
    private var readGeneration = 0
    private var reading = false
    private var timer: Timer?
    private var current: ActionRun?

    /// How often the status is read.
    static let refreshInterval: TimeInterval = 5

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    var status: Status? {
        switch page {
        case .status(.installed(let s)), .status(.unreadable(let s)): return s
        default: return nil
        }
    }

    var installed: Bool { status?.install.installed == true }

    var glyph: Glyph {
        switch page {
        case .loading: return .grey
        case .missing: return .red
        case .status(let v): return Glyph.of(v)
        }
    }

    /// The bridges switch: what the user asked for while it runs, else what
    /// the status says (absent or anything but `off` is on, as the command reads it).
    var bridgesOn: Bool { bridgesPending ?? (status?.bridges.mode != "off") }

    var keptSource: Bool { CommandPaths.keptSourceExists(home: environment["HOME"] ?? NSHomeDirectory()) }

    // MARK: Status

    /// Show a page read elsewhere (the screenshot hook reads once, synchronously).
    func show(_ p: Page) { page = p }

    func startRefreshing() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: AppModel.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Read the status in the background and show it; a read started before
    /// an action ended is dropped, as is one while another is under way.
    func refresh() {
        guard !reading else { return }
        reading = true
        let generation = readGeneration
        let env = environment
        DispatchQueue.global().async { [weak self] in
            let page = AppModel.read(environment: env)
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                if generation == self.readGeneration { self.page = page }
            }
        }
    }

    /// One status read, start to end (also the screenshot hook's).
    static func read(environment env: [String: String]) -> Page {
        let argv: [String]
        do {
            argv = try CommandPaths.statusArgv(environment: env)
        } catch let nf as CommandNotFound {
            return .missing(nf.path)
        } catch {
            return .status(.error("\(error)"))
        }
        guard !argv.isEmpty else { return .status(.error("the status command is empty")) }
        do {
            let r = try CommandRunner.collect(argv, environment: CommandPaths.childEnvironment(env))
            var code: Int32?
            if case .code(let c)? = r.exit { code = c }
            return .status(classify(exit: code, stdout: r.stdout.map { $0 + "\n" }.joined()))
        } catch {
            return .status(.error("cannot run \(argv[0]): \(error)"))
        }
    }

    // MARK: Actions

    /// The way in for a button or a menu item: ask first where the table
    /// says so, then run.
    func request(_ id: String) {
        guard !busy else { notice = "Another action is running"; return }
        switch id {
        case "uninstall": confirm = .uninstall
        case "reinstall": confirm = .reinstall(defaultChoices())
        case "update": confirm = .update(status?.update.remoteCommit)
        default: run(id)
        }
    }

    func defaultChoices() -> Choices {
        Choices(variant: status?.install.variant ?? "haproxy",
                pihole: status?.install.pihole ?? "standard",
                branch: status?.install.branch ?? "main")
    }

    func setBridges(_ on: Bool) {
        guard on != bridgesOn else { return }
        run(on ? "bridges-on" : "bridges-off")
    }

    /// Run action `id` now, one at a time, its output streamed into the pane.
    func run(_ id: String, choices: Choices? = nil) {
        guard !busy else { notice = "Another action is running"; return }
        let label = Actions.lookup(id)?.label ?? id
        if Actions.lookup(id)?.program == nil { return runInApp(id, label: label) }
        switch id {
        case "bridges-on": bridgesPending = true
        case "bridges-off": bridgesPending = false
        default: break
        }
        busy = true
        paneTitle = label
        paneResult = "running…"
        paneOK = true
        paneText = ""
        let run = ActionRun(id: id)
        current = run
        run.start(choices: choices, environment: environment, queue: .main) { [weak self] r in
            guard let self else { return }
            self.paneText = r.paneText
            if r.end != nil { self.ended(r) }
        }
    }

    private func ended(_ r: ActionRun) {
        busy = false
        bridgesPending = nil
        current = nil
        paneResult = r.said ?? ""
        paneOK = r.end.map { succeeded(id: r.id, end: $0) } ?? false
        if !paneOK { notice = "\(paneTitle): \(paneResult)" }
        // Re-read everything: a switch the command did not turn goes back.
        readGeneration += 1
        reading = false
        refresh()
        if r.id == "update-check", case .exit(.code(10))? = r.end {
            let found = r.paneLines.last(where: { $0.hasPrefix("available ") }).map { String($0.dropFirst("available ".count)) }
            confirm = .update(found ?? status?.update.remoteCommit)
        }
    }

    /// The actions that run no command.
    private func runInApp(_ id: String, label: String) {
        paneTitle = label
        paneOK = true
        switch id {
        case "open-admin":
            if let u = status?.admin.url, let url = URL(string: u) {
                NSWorkspace.shared.open(url)
                paneText = "opened \(u)\n"
                paneResult = "opened in the browser"
            } else {
                paneText = ""
                paneResult = "the status names no admin page"
                paneOK = false
            }
        case "show-password-path":
            let p = status?.admin.passwordPath ?? "unknown"
            paneText = p + "\n"
            paneResult = "the admin password is in this file"
        default:
            paneText = ""
            paneResult = "nothing to run"
        }
    }

    var actionRunning: Bool { current != nil }
}
