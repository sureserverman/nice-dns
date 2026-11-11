// The window: the stack's state from `nice-dns status --tsv`, each action
// where Placement puts it (a button, the bridges switch, a selector, the
// update banner) and the log pane. It shows and runs; it never changes the install
// itself (DEC-018).
import AppKit
import NiceDNSKit
import SwiftUI

extension Glyph {
    var color: Color {
        switch self {
        case .grey: return .gray
        case .green: return .green
        case .amber: return .orange
        case .red: return .red
        }
    }
}

struct WindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    page
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            LogPane(model: model)
                .frame(height: 170)
        }
        .frame(minWidth: 640, minHeight: 560)
        // Drawn by the view itself, so the screenshot hook has it too.
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $model.confirm) { c in
            ConfirmSheet(model: model, confirm: c)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .loading:
            Text("Reading the status…").foregroundColor(.secondary)
        case .missing(let path):
            ErrorPage(title: "nice-dns is not installed where the app looks",
                      detail: "nice-dns command not found: looked for \(path)")
        case .status(.error(let message)):
            ErrorPage(title: "The status cannot be shown", detail: message)
        case .status(.notInstalled(let hint, let unreadable)):
            NotInstalledPage(model: model, hint: hint, unreadable: unreadable)
        case .status(.installed(let s)):
            StatusPage(model: model, status: s)
        case .status(.unreadable(let s)):
            StatusPage(model: model, status: s)
        }
    }
}

struct ErrorPage: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.title2).foregroundColor(.red)
            Text(detail).textSelection(.enabled).font(.body.monospaced())
        }
    }
}

struct NotInstalledPage: View {
    @ObservedObject var model: AppModel
    let hint: String?
    let unreadable: [Unreadable]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("nice-dns is not installed on this Mac", systemImage: "circle.dashed")
                .font(.title2)
            Text("Install it from a terminal with the line in the README:")
            Text(hint ?? "see the README").textSelection(.enabled).font(.body.monospaced())
                .padding(8).background(Color.secondary.opacity(0.1)).cornerRadius(6)
            ForEach(unreadable, id: \.group) { u in
                Text("\(u.group) cannot be read: \(u.reason)").foregroundColor(.orange)
            }
            if model.keptSource {
                Button("Install") { model.request(Placement.install) }.disabled(model.busy)
            }
        }
    }
}

struct StatusPage: View {
    @ObservedObject var model: AppModel
    let status: Status

    private var stale: Bool { status.controller.stale != Stale.no }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if status.update.result == .available {
                updateBanner
            }
            ForEach(status.unreadable, id: \.group) { u in
                Label("\(u.group) cannot be read: \(u.reason)", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
            }
            Panel(title: "Installed") {
                ForEach(StackChoice.all, id: \.kind) { c in
                    ChoiceRow(model: model, choice: c)
                }
                Row("Update", updateRow(status.update, now: UInt64(max(0, Date().timeIntervalSince1970))))
            }
            Group {
                Panel(title: "Containers") {
                    ForEach(status.obs.filter { $0.name.hasPrefix("container:") }, id: \.name) { o in
                        VerdictRow(name: String(o.name.dropFirst("container:".count)), verdict: o.verdict, reason: o.reason, stale: stale)
                    }
                }
                Panel(title: "Observations") {
                    ForEach(status.obs.filter { !$0.name.hasPrefix("container:") }, id: \.name) { o in
                        VerdictRow(name: o.name, verdict: o.verdict, reason: o.reason, stale: stale)
                    }
                }
                Panel(title: "Bridges") {
                    Toggle("Tor bridges", isOn: Binding(get: { model.bridgesOn }, set: { model.setBridges($0) }))
                        .toggleStyle(.switch).disabled(model.busy)
                    Row("Bridges known", status.bridges.count.map(String.init) ?? "unknown")
                    Row("Last refresh", moment(status.bridges.lastRefresh))
                }
                Panel(title: "Controller") {
                    Row("Verdict", status.controller.verdict ?? "unknown")
                    Row("Last pass", moment(status.controller.lastPass))
                    Row("Freshness", status.controller.stale.map { "\($0)" } ?? "unknown")
                    Row("Schedule", status.controller.schedule ?? "unknown")
                    Row("Route", status.route?.id ?? "none")
                    Row("Helper", helper)
                }
                Panel(title: "Recent actions") {
                    if status.recent.isEmpty { Text("none").foregroundColor(.secondary) }
                    ForEach(Array(status.recent.enumerated()), id: \.offset) { _, r in
                        Row(moment(r.epoch.map(Moment.at)), "\(r.target) \(r.result)")
                    }
                }
            }
            .opacity(stale ? 0.5 : 1)
            Panel(title: "Admin") {
                HStack {
                    Button("Open the admin page") { model.request(Placement.openAdmin) }
                    Button("Show where the password is") { model.request(Placement.showPasswordPath) }
                }
            }
            actions
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle().fill(model.glyph.color).frame(width: 12, height: 12)
            Text("nice-dns").font(.title2.bold())
            Text("\(status.install.variant ?? "?"), Pi-hole \(status.install.pihole ?? "?"), branch \(status.install.branch ?? "?")")
                .foregroundColor(.secondary)
            Spacer()
            if stale, let s = status.controller.stale {
                Text(s.description).foregroundColor(.orange).bold()
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text("generation \(status.install.generation ?? "unknown")")
                .font(.caption.monospaced()).foregroundColor(.secondary).offset(y: 16)
        }
        .padding(.bottom, 14)
    }

    private var updateBanner: some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("A different version is available" + (status.update.remoteCommit.map { ": " + String($0.prefix(12)) } ?? ""))
            Spacer()
            Button("Install it…") { model.request(Placement.updateBanner) }.disabled(model.busy)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.12))
        .cornerRadius(6)
    }

    private var actions: some View {
        Panel(title: "Actions") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading) {
                // The plain buttons only: every other row has its own place (Placement).
                ForEach(Placement.buttons(), id: \.id) { a in
                    Button(a.label + (a.needsConfirm ? "…" : "")) { model.request(a.id) }
                        .disabled(model.busy)
                }
            }
        }
    }

    private var helper: String {
        switch status.helper.installed {
        case true?: return "installed" + (status.helper.version.map { " (\($0))" } ?? "")
        case false?: return "not installed"
        case nil: return "unknown"
        }
    }
}

/// A selector: the proxy or the Pi-hole flavour, set to what the status
/// says, or to the choice asked about or running. Unknown and disabled when
/// the status names neither choice; disabled while any action runs.
struct ChoiceRow: View {
    @ObservedObject var model: AppModel
    let choice: StackChoice

    var body: some View {
        let shown = model.shown(choice)
        HStack {
            Text(choice.title).foregroundColor(.secondary).frame(width: 150, alignment: .leading)
            Picker(choice.title, selection: Binding(get: { shown ?? "unknown" }, set: { model.pick(choice, $0) })) {
                ForEach(choice.choices, id: \.self) { Text($0).tag($0) }
                if shown == nil { Text("unknown").tag("unknown") }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 160)
            .disabled(model.busy || shown == nil)
            Spacer()
        }
    }
}

func moment(_ m: Moment?) -> String {
    switch m {
    case .at(let t)?:
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    case .never?: return "never"
    case nil: return "unknown"
    }
}

struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        GroupBox(label: Text(title).font(.headline)) {
            VStack(alignment: .leading, spacing: 4) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        }
    }
}

struct Row: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        HStack {
            Text(title).foregroundColor(.secondary).frame(width: 150, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
    }
}

struct VerdictRow: View {
    let name: String
    let verdict: String
    let reason: String
    let stale: Bool
    var body: some View {
        HStack {
            Text(name).frame(width: 200, alignment: .leading)
            Text(reason).foregroundColor(.secondary).lineLimit(1)
            Spacer()
            Text(verdict).bold().foregroundColor(stale ? .secondary : color)
        }
    }
    private var color: Color {
        switch verdict {
        case "healthy": return .green
        case "unhealthy": return .red
        default: return .orange
        }
    }
}

struct LogPane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.paneTitle.isEmpty ? "Output" : model.paneTitle).font(.headline)
                Spacer()
                Text(model.paneResult).foregroundColor(model.paneOK ? .green : .red)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.paneText.isEmpty ? "The output of an action shows here." : model.paneText)
                        .font(.caption.monospaced())
                        .foregroundColor(model.paneText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: model.paneText) { _ in proxy.scrollTo("end") }
            }
            if let n = model.notice {
                Text(n).foregroundColor(.red).font(.caption)
            }
        }
        .padding(10)
    }
}

/// The questions asked before uninstall, reinstall, update and a switch.
struct ConfirmSheet: View {
    @ObservedObject var model: AppModel
    let confirm: Confirm
    @State private var typed = ""
    @State private var variant = ""
    @State private var pihole = ""
    @State private var branch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch confirm {
            case .uninstall:
                Text("Uninstall nice-dns?").font(.title3.bold())
                Text("The containers, the controller and the DNS pin are removed, and DNS is given back to the system. Type uninstall to go ahead.")
                    .fixedSize(horizontal: false, vertical: true)
                TextField("uninstall", text: $typed).textFieldStyle(.roundedBorder)
                buttons(go: "Uninstall", enabled: typed == "uninstall") { model.run("uninstall") }
            case .reinstall(let c):
                Text("Reinstall the stack").font(.title3.bold())
                Picker("Proxy", selection: $variant) { Text("haproxy").tag("haproxy"); Text("socat").tag("socat") }
                Picker("Pi-hole", selection: $pihole) { Text("standard").tag("standard"); Text("hardened").tag("hardened") }
                TextField("Branch", text: $branch).textFieldStyle(.roundedBorder)
                buttons(go: "Reinstall", enabled: !branch.trimmingCharacters(in: .whitespaces).isEmpty) {
                    model.run("reinstall", choices: Choices(variant: variant, pihole: pihole, branch: branch))
                }
                .onAppear { variant = c.variant; pihole = c.pihole; branch = c.branch }
            case .reinstallKeep:
                Text("Reinstall nice-dns?").font(.title3.bold())
                Text("The status does not say which choices are installed, so the reinstall keeps the recorded ones.")
                    .fixedSize(horizontal: false, vertical: true)
                buttons(go: "Reinstall", enabled: true) { model.run("reinstall") }
            case .update(let commit):
                Text("Install the update?").font(.title3.bold())
                Text("A different version is available" + (commit.map { ": " + String($0.prefix(12)) } ?? "") + ". The branch's current commit is installed like a reinstall.")
                    .fixedSize(horizontal: false, vertical: true)
                buttons(go: "Install", enabled: true, cancel: "Not now") { model.run(Placement.updateBanner) }
            case .switchTo(let id):
                Text(Actions.lookup(id)?.label ?? id).font(.title3.bold())
                Text(StackChoice.question(for: id) ?? id)
                    .fixedSize(horizontal: false, vertical: true)
                buttons(go: "Switch", enabled: true, cancel: "Not now") { model.run(id) }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func buttons(go: String, enabled: Bool, cancel: String = "Cancel", action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(cancel) { model.confirm = nil }.keyboardShortcut(.cancelAction)
            Button(go) { model.confirm = nil; action() }.keyboardShortcut(.defaultAction).disabled(!enabled)
        }
    }
}
