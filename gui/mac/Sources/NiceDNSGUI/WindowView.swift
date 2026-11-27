// The window: a switcher drawn inside the view (so the screenshot hook has
// it too) over three views of the stack (Overview, Checks, Setup), the
// action bar and its output drawer at the bottom, and the pages that replace
// the views when there is no stack to show. It shows and runs; it never
// changes the install itself (DEC-018).
import AppKit
import NiceDNSKit
import SwiftUI

struct WindowView: View {
    @ObservedObject var model: AppModel

    /// The content's width: one column, centred.
    static let contentMaxWidth: CGFloat = 720

    var body: some View {
        VStack(spacing: 0) {
            if let s = model.status {
                SwitcherBar(model: model)
                Divider()
                ScrollView {
                    page(s)
                        .padding(.vertical, 28)
                        .padding(.horizontal, 56)
                        .frame(maxWidth: WindowView.contentMaxWidth + 112)
                        .frame(maxWidth: .infinity)
                }
            } else {
                ScrollView {
                    otherPage
                        .padding(.vertical, 28)
                        .padding(.horizontal, 56)
                        .frame(maxWidth: WindowView.contentMaxWidth + 112, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            }
            if model.barVisible {
                Divider()
                ActionBar(model: model)
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        // Drawn by the view itself, so the screenshot hook has it too.
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Toast(model: model).padding(.bottom, model.barVisible ? 70 : 0)
        }
        .tint(Palette.accent)
        .sheet(item: $model.confirm) { c in
            ConfirmSheet(model: model, confirm: c)
        }
    }

    @ViewBuilder private func page(_ s: Status) -> some View {
        switch model.view {
        case .overview: OverviewView(model: model, status: s)
        case .checks: ChecksView(model: model, status: s)
        case .setup: SetupView(model: model, status: s)
        }
    }

    /// The pages that replace the three views: loading, the command missing,
    /// an error and not installed. They hide the switcher.
    @ViewBuilder private var otherPage: some View {
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
        case .status(.installed), .status(.unreadable):
            EmptyView()
        }
    }
}

/// Overview, Checks and Setup as a segmented control, centred, with the
/// number of checks that need attention beside Checks. ⌘1, ⌘2 and ⌘3 pick them.
struct SwitcherBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Spacer()
            Picker("View", selection: $model.view) {
                ForEach(ViewTab.allCases) { tab in
                    Text(label(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            Spacer()
        }
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func label(_ tab: ViewTab) -> String {
        tab == .checks && model.attentionCount > 0 ? "Checks (\(model.attentionCount))" : tab.title
    }
}

struct ErrorPage: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold()).foregroundStyle(Palette.icon(.down))
            Text(detail).textSelection(.enabled).font(.system(size: 13, design: .monospaced))
            Button("Copy Details") { copyToPasteboard("\(title)\n\(detail)\n") }
        }
    }
}

struct NotInstalledPage: View {
    @ObservedObject var model: AppModel
    let hint: String?
    let unreadable: [Unreadable]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("nice-dns is not installed").font(.title.bold())
            } icon: {
                Image(systemName: Level.notInstalled.heroSymbol).foregroundStyle(Palette.icon(.neutral))
            }
            .font(.title)
            Text("Install it from a terminal with this line:").foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                Text(hint ?? "see the README").textSelection(.enabled).font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") { copyToPasteboard(hint ?? "") }.disabled(hint == nil)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.inset))
            ForEach(unreadable, id: \.group) { u in
                Label("\(u.group) cannot be read: \(u.reason)", systemImage: Tone.attention.symbol)
                    .foregroundStyle(Palette.text(.attention))
            }
            if model.keptSource {
                Button("Install nice-dns") { model.request(Placement.install) }
                    .buttonStyle(SuggestedButtonStyle()).disabled(model.busy)
            }
        }
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
                Text("This removes the stack and what it keeps (Tor state, the Pi-hole lists, the admin password) and the nice-dns command, and gives DNS back to the system. Type uninstall to go ahead.")
                    .fixedSize(horizontal: false, vertical: true)
                TextField("uninstall", text: $typed).textFieldStyle(.roundedBorder)
                buttons(go: "Uninstall", enabled: typed == "uninstall") { model.run(Placement.uninstall) }
            case .reinstall(let c):
                Text("Reinstall nice-dns?").font(.title3.bold())
                Picker("Tor proxy", selection: $variant) { Text("haproxy").tag("haproxy"); Text("socat").tag("socat") }
                Picker("Pi-hole image", selection: $pihole) { Text("standard").tag("standard"); Text("hardened").tag("hardened") }
                TextField("Branch", text: $branch).textFieldStyle(.roundedBorder)
                buttons(go: "Reinstall", enabled: !branch.trimmingCharacters(in: .whitespaces).isEmpty) {
                    model.run(Placement.reinstall, choices: Choices(variant: variant, pihole: pihole, branch: branch))
                }
                .onAppear { variant = c.variant; pihole = c.pihole; branch = c.branch }
            case .reinstallKeep:
                Text("Reinstall nice-dns?").font(.title3.bold())
                Text("The status does not say which choices are installed, so the reinstall keeps the recorded ones.")
                    .fixedSize(horizontal: false, vertical: true)
                buttons(go: "Reinstall", enabled: true) { model.run(Placement.reinstall) }
            case .update(let commit):
                Text("Install the update?").font(.title3.bold())
                Text("A different version is available" + (commit.map { ": " + shortCommit($0) } ?? "") + ". The branch's current commit is installed like a reinstall.")
                    .fixedSize(horizontal: false, vertical: true)
                buttons(go: "Install", enabled: true, cancel: "Not now") { model.run(Placement.update) }
            case .switchTo(let id):
                Text(StackChoice.dialogTitle(for: id) ?? id).font(.title3.bold())
                Text(StackChoice.dialogBody)
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
