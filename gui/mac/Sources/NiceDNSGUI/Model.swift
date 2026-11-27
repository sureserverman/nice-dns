// The app's state: the last status read, the view shown, the action running
// and its output. The window and the menu-bar panel both read it; every
// action goes through `run`.
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

/// The three views of an installed stack, in the order of the switcher (⌘1, ⌘2, ⌘3).
enum ViewTab: String, CaseIterable, Identifiable {
    case overview, checks, setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .checks: return "Checks"
        case .setup: return "Setup"
        }
    }
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

/// One line of the output drawer.
struct PaneRow: Identifiable, Equatable {
    let id: Int
    let text: String
    let kind: PaneKind
}

final class AppModel: ObservableObject {
    @Published private(set) var page: Page = .loading
    @Published var view: ViewTab = .overview
    @Published private(set) var busy = false
    /// The action's label (the bar says more); empty until the first action.
    @Published private(set) var paneTitle = ""
    /// The id of the action the bar is about; empty when there is no bar.
    @Published private(set) var paneID = ""
    @Published private(set) var paneText = ""
    @Published private(set) var paneRows: [PaneRow] = []
    @Published private(set) var paneResult = ""
    @Published private(set) var paneOK = true
    /// The bar's title once the action ended: its own last line, or "{label}: finished".
    @Published private(set) var paneResultTitle = ""
    /// The outcome line, or for a switch the sentence that says it did not happen.
    @Published private(set) var paneDetail = ""
    /// The command's latest output line, for the running bar.
    @Published private(set) var paneLatest = ""
    @Published private(set) var paneStarted: Date?
    @Published private(set) var paneElapsed = 0
    /// The output drawer; it opens by itself when an action fails.
    @Published var outputOpen = false
    /// Counts the actions that ended in failure: the menu-bar app opens the window then (D4).
    @Published private(set) var failureCount = 0
    /// The bridges switch as the user last set it, until the command ends;
    /// then the status decides again, so a switch that failed goes back.
    @Published private(set) var bridgesPending: Bool?
    /// The same for the automatic-checks switch.
    @Published private(set) var autoPending: Bool?
    /// The two selectors' choice asked about or running (NiceDNSKit.SwitchState).
    @Published private(set) var switches = SwitchState()
    /// The Checks groups the person opened or closed, while the window is open.
    @Published var groupOpen: [String: Bool] = [:]
    /// The checks opened to their raw record, while the window is open.
    @Published var rowOpen: Set<String> = []
    /// A switch question answered Not now or dismissed puts its selector back.
    @Published var confirm: Confirm? {
        didSet {
            if confirm == nil, case .switchTo? = oldValue { switches.dismiss() }
        }
    }
    /// A toast, for what has no output: "Another action is running", "Could not open {url}".
    @Published var notice: String?
    /// A path the toast offers to copy.
    @Published private(set) var noticeCopy: String?

    let environment: [String: String]
    private var readGeneration = 0
    private var reading = false
    private var timer: Timer?
    private var current: ActionRun?
    /// A pane update is due: chatty output is shown at most every 0.1 s.
    private var paneScheduled = false
    /// The switches keep what the user set until the read after the action
    /// lands, so a switch that worked does not flick back first.
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

    /// The time every "ago" is counted from. `NICE_DNS_GUI_NOW` (an epoch)
    /// pins it for the screenshot hook, so a capture does not depend on the clock.
    var now: UInt64 {
        if let s = environment["NICE_DNS_GUI_NOW"], let n = UInt64(s) { return n }
        return UInt64(max(0, Date().timeIntervalSince1970))
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

    /// The level of what is shown; nil while the first read is under way.
    var level: Level? {
        switch page {
        case .loading: return nil
        case .missing: return .error
        case .status(let v): return Level.of(v)
        }
    }

    var glyph: Glyph { level?.glyph ?? .grey }

    var menuSymbol: String { level?.menuSymbol ?? Level.loadingMenuSymbol }

    /// The status header's copy; the same one the window and the panel draw.
    var hero: Hero {
        switch page {
        case .loading: return .loading
        case .missing(let p): return Hero(level: .error, title: "nice-dns command not found", subtitle: "Looked for \(p)", action: nil)
        case .status(let v): return NiceDNSKit.hero(v, now: now)
        }
    }

    /// How many checks are not healthy: the Checks tab's count.
    var attentionCount: Int { status.map { notHealthy($0).count } ?? 0 }

    /// The bridges switch: what the user asked for while it runs, else what
    /// the status says (absent or anything but `off` is on, as the command reads it).
    var bridgesOn: Bool { bridgesPending ?? (status?.bridges.mode != "off") }

    /// The automatic-checks switch: what the user asked for while it runs, else the schedule.
    var autoOn: Bool { autoPending ?? (status.map(autoChecksOn) ?? false) }

    /// What `selector` shows; nil (unknown) when the status names neither choice.
    func shown(_ selector: StackChoice) -> String? { switches.shown(selector, status: status) }

    var keptSource: Bool { CommandPaths.keptSourceExists(home: environment["HOME"] ?? NSHomeDirectory()) }

    /// The action bar is shown while an action runs and after it, until dismissed.
    var barVisible: Bool { busy || !paneID.isEmpty }

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
                    self.autoPending = nil
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

    /// The way in for a button or a panel row: ask first where the table
    /// says so, then run.
    func request(_ id: String) {
        // Opening the admin page or showing a path runs no command: never refused.
        if let a = Actions.lookup(id), a.program == nil { return runInApp(id) }
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
        case Placement.uninstall: confirm = .uninstall
        case Placement.reinstall: confirm = defaultChoices().map(Confirm.reinstall) ?? .reinstallKeep
        case Placement.update: confirm = .update(status?.update.remoteCommit)
        default: run(id)
        }
    }

    /// The reinstall dialog's choices, from the status; nil when it does not
    /// say the proxy or the Pi-hole flavour (they are never guessed).
    func defaultChoices() -> Choices? {
        guard let v = status?.install.variant, let p = status?.install.pihole else { return nil }
        return Choices(variant: v, pihole: p, branch: status?.install.branch ?? "main")
    }

    /// A toast, cleared after 8 s or by the next action; `copy` is a path it offers to copy.
    func say(_ text: String, copy: String? = nil) {
        noticeToken += 1
        let token = noticeToken
        notice = text
        noticeCopy = copy
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.noticeToken == token { self?.notice = nil; self?.noticeCopy = nil }
        }
    }

    /// A selector was set to `choice`: ask, then switch (DEC-018).
    func pick(_ selector: StackChoice, _ choice: String) {
        guard selector.choices.contains(choice) else { return }
        request(selector.id(choice))
    }

    func setBridges(_ on: Bool) {
        guard on != bridgesOn else { return }
        run(on ? Placement.bridgesOn : Placement.bridgesOff)
    }

    /// The automatic-checks switch, and the status header's Turn On: `health-start` or `health-stop`.
    func setAuto(_ on: Bool) {
        guard on != autoOn else { return }
        run(on ? Placement.healthStart : Placement.healthStop)
    }

    /// Run action `id` now, one at a time, its output streamed into the pane.
    func run(_ id: String, choices: Choices? = nil) {
        let label = Actions.lookup(id)?.label ?? id
        if Actions.lookup(id)?.program == nil { return runInApp(id) }
        guard !busy else { say("Another action is running"); return }
        noticeToken += 1
        notice = nil
        noticeCopy = nil
        switch id {
        // A read still due from the last action must not undo this switch.
        case Placement.bridgesOn: bridgesPending = true; clearPendingOnRead = false
        case Placement.bridgesOff: bridgesPending = false; clearPendingOnRead = false
        case Placement.healthStart: autoPending = true; clearPendingOnRead = false
        case Placement.healthStop: autoPending = false; clearPendingOnRead = false
        default: break
        }
        switches.started(id)
        busy = true
        quitAsked = nil
        paneID = id
        paneTitle = label
        paneResult = "running…"
        paneResultTitle = ""
        paneDetail = ""
        paneOK = true
        paneText = ""
        paneRows = []
        paneLatest = ""
        paneStarted = Date()
        paneElapsed = 0
        outputOpen = false
        let run = ActionRun(id: id)
        current = run
        run.start(choices: choices, environment: environment, queue: .main) { [weak self] r in
            guard let self, self.current === r else { return }
            if r.end != nil {
                self.updatePane(from: r)
                return self.ended(r)
            }
            guard !self.paneScheduled else { return }
            self.paneScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.paneScheduled = false
                if let c = self.current, c === r { self.updatePane(from: c) }
            }
        }
    }

    private func updatePane(from r: ActionRun) {
        paneText = r.paneText
        paneRows = zip(r.paneLines, r.paneKinds).enumerated().map { PaneRow(id: $0.offset, text: $0.element.0, kind: $0.element.1) }
        paneLatest = r.outputLines.last ?? ""
    }

    private func ended(_ r: ActionRun) {
        busy = false
        clearPendingOnRead = true
        current = nil
        paneElapsed = Int(Date().timeIntervalSince(paneStarted ?? Date()))
        paneResult = r.said ?? ""
        paneOK = r.end.map { succeeded(id: r.id, end: $0) } ?? false
        paneResultTitle = resultTitle(r.id, lines: r.outputLines)
        paneDetail = paneOK ? paneResult : (StackChoice.failedNotice(for: r.id, said: paneResult) ?? paneResult)
        // A failed switch puts its selector back now; one that worked waits for the read.
        switches.ended(r.id, succeeded: paneOK)
        if !paneOK {
            // The failed bar opens the output by itself; the menu-bar app opens the window (D4).
            outputOpen = true
            failureCount += 1
        }
        // Re-read everything: a switch the command did not turn goes back.
        readGeneration += 1
        reading = false
        refresh()
        if r.id == Placement.updateCheck, case .exit(.code(10))? = r.end {
            let found = r.paneLines.last(where: { $0.hasPrefix("available ") }).map { String($0.dropFirst("available ".count)) }
            confirm = .update(found ?? status?.update.remoteCommit)
        }
    }

    /// The finished bar goes away; a running one cannot be dismissed.
    func dismissBar() {
        guard !busy else { return }
        paneID = ""
        outputOpen = false
    }

    /// The actions that run no command. They never touch the bar: what they
    /// have to say is a toast.
    private func runInApp(_ id: String) {
        switch id {
        case Placement.openAdmin:
            // Only a web page: the URL comes from the status, opened as a link.
            if let u = status?.admin.url, let url = URL(string: u), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                if !NSWorkspace.shared.open(url) { say("Could not open \(u)") }
            } else {
                say("Could not open the admin page: the status names none")
            }
        case Placement.showPasswordPath:
            revealPasswordFile()
        default:
            break
        }
    }

    /// Show the admin password's file in Finder; when it cannot be shown, the
    /// toast names the path and offers to copy it.
    private func revealPasswordFile() {
        guard let path = status?.admin.passwordPath, !path.isEmpty else {
            return say("Could not show the password file: the status names none")
        }
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            say("The admin password is in this file: \(path)", copy: path)
        }
    }

    var actionRunning: Bool { current != nil }
}
