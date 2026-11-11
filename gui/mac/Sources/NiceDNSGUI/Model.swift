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
    /// The status does not say which choices are installed: the reinstall
    /// keeps the recorded ones, nothing is guessed.
    case reinstallKeep
    case update(String?)
    /// A switch of the proxy or the Pi-hole flavour: the choice's action id.
    case switchTo(String)

    var id: String {
        switch self {
        case .uninstall: return "uninstall"
        case .reinstall: return "reinstall"
        case .reinstallKeep: return "reinstall-keep"
        case .update: return "update"
        case .switchTo: return "switch"
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
    /// The two selectors' choice asked about or running (NiceDNSKit.SwitchState).
    @Published private(set) var switches = SwitchState()
    /// A switch question answered Not now or dismissed puts its selector back.
    @Published var confirm: Confirm? {
        didSet {
            if confirm == nil, case .switchTo? = oldValue { switches.dismiss() }
        }
    }
    @Published var notice: String?

    let environment: [String: String]
    private var readGeneration = 0
    private var reading = false
    private var timer: Timer?
    private var current: ActionRun?
    /// A pane update is due: chatty output is shown at most every 0.1 s.
    private var paneScheduled = false
    /// The bridges switch keeps what the user set until the read after the
    /// action lands, so a switch that worked does not flick back first.
    private var clearPendingOnRead = false
    private var noticeToken = 0
    /// When Quit was refused because an action runs: a second Quit within
    /// 10 s goes through (a command that hangs must not trap the owner). A
    /// new action starts the count again.
    var quitAsked: Date?

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

    /// A stack the status describes: installed, or installed with a file it
    /// cannot read (Uninstall and Restart are wanted most then).
    var installed: Bool {
        switch page {
        case .status(.installed), .status(.unreadable): return true
        default: return false
        }
    }

    var notInstalled: Bool {
        if case .status(.notInstalled) = page { return true }
        return false
    }

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

    /// What `selector` shows; nil (unknown) when the status names neither choice.
    func shown(_ selector: StackChoice) -> String? { switches.shown(selector, status: status) }

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
                guard generation == self.readGeneration else { return }
                self.page = page
                self.switches.statusRead()
                if self.clearPendingOnRead {
                    self.clearPendingOnRead = false
                    self.bridgesPending = nil
                }
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
        // Opening the admin page or showing a path runs no command: never refused.
        if let a = Actions.lookup(id), a.program == nil { return runInApp(id, label: a.label) }
        guard !busy else { say("Another action is running"); return }
        if let p = StackChoice.choice(of: id) {
            // Never guessed: a selector the status does not name is disabled.
            guard let installed = p.selector.installed(in: status) else {
                return say("The status does not say which \(p.selector.title) is installed")
            }
            guard p.choice != installed else { return }
            switches.ask(id)
            confirm = .switchTo(id)
            return
        }
        switch id {
        case "uninstall": confirm = .uninstall
        case "reinstall": confirm = defaultChoices().map(Confirm.reinstall) ?? .reinstallKeep
        case "update": confirm = .update(status?.update.remoteCommit)
        default: run(id)
        }
    }

    /// The reinstall dialog's choices, from the status; nil when it does not
    /// say the proxy or the Pi-hole flavour (they are never guessed).
    func defaultChoices() -> Choices? {
        guard let v = status?.install.variant, let p = status?.install.pihole else { return nil }
        return Choices(variant: v, pihole: p, branch: status?.install.branch ?? "main")
    }

    /// A short notice under the pane, cleared after 8 s or by the next action.
    func say(_ text: String) {
        noticeToken += 1
        let token = noticeToken
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.noticeToken == token { self?.notice = nil }
        }
    }

    /// A selector was set to `choice`: ask, then switch (DEC-018).
    func pick(_ selector: StackChoice, _ choice: String) {
        guard selector.choices.contains(choice) else { return }
        request(selector.id(choice))
    }

    func setBridges(_ on: Bool) {
        guard on != bridgesOn else { return }
        run(on ? "bridges-on" : "bridges-off")
    }

    /// Run action `id` now, one at a time, its output streamed into the pane.
    func run(_ id: String, choices: Choices? = nil) {
        let label = Actions.lookup(id)?.label ?? id
        if Actions.lookup(id)?.program == nil { return runInApp(id, label: label) }
        guard !busy else { say("Another action is running"); return }
        noticeToken += 1
        notice = nil
        switch id {
        // A read still due from the last action must not undo this switch.
        case "bridges-on": bridgesPending = true; clearPendingOnRead = false
        case "bridges-off": bridgesPending = false; clearPendingOnRead = false
        default: break
        }
        switches.started(id)
        busy = true
        quitAsked = nil
        paneTitle = label
        paneResult = "running…"
        paneOK = true
        paneText = ""
        let run = ActionRun(id: id)
        current = run
        run.start(choices: choices, environment: environment, queue: .main) { [weak self] r in
            guard let self, self.current === r else { return }
            if r.end != nil {
                self.paneText = r.paneText
                return self.ended(r)
            }
            guard !self.paneScheduled else { return }
            self.paneScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.paneScheduled = false
                if let c = self.current, c === r { self.paneText = c.paneText }
            }
        }
    }

    private func ended(_ r: ActionRun) {
        busy = false
        clearPendingOnRead = true
        current = nil
        paneResult = r.said ?? ""
        paneOK = r.end.map { succeeded(id: r.id, end: $0) } ?? false
        // A failed switch puts its selector back now; one that worked waits for the read.
        switches.ended(r.id, succeeded: paneOK)
        if !paneOK { say(StackChoice.failedNotice(for: r.id, said: paneResult) ?? "\(paneTitle): \(paneResult)") }
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
    /// The actions that run no command. While a command runs its pane stays;
    /// the answer goes in a notice instead.
    private func runInApp(_ id: String, label: String) {
        let said: String
        var text = ""
        var ok = true
        switch id {
        case "open-admin":
            // Only a web page: the URL comes from the status, opened as a link.
            if let u = status?.admin.url, let url = URL(string: u), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                text = "opened \(u)"
                said = "opened in the browser"
            } else {
                said = "the status names no admin web page"
                ok = false
            }
        case "show-password-path":
            text = status?.admin.passwordPath ?? "unknown"
            said = "the admin password is in this file"
        default:
            said = "nothing to run"
        }
        if busy {
            return say(text.isEmpty ? said : "\(text): \(said)")
        }
        paneTitle = label
        paneText = text.isEmpty ? "" : text + "\n"
        paneResult = said
        paneOK = ok
    }

    var actionRunning: Bool { current != nil }
}
