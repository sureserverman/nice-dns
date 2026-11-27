// The menu-bar panel: what the status item opens. A compact status header,
// the path as one line, the bridges switch with its cost, the three
// everyday actions, then Open nice-dns and Quit. It draws a subset of the
// window's places and reads the same model, so it can never disagree with
// the window. While an action runs its header says so and its controls wait.
import AppKit
import NiceDNSKit
import SwiftUI

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    /// Closes the popover (Open, Quit and the actions that leave the app).
    let close: () -> Void
    let openWindow: () -> Void

    static let width: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            if let s = model.status {
                Text(pathLine(s))
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.tint(.neutral)))
                    .padding(.horizontal, 16).padding(.bottom, 14)
                    .accessibilityLabel("Path: \(pathLine(s))")
            }
            Divider()
            if let s = model.status {
                if s.update.result == .available {
                    UpdateRowView(model: model, status: s)
                    Divider()
                }
                bridges
                PanelRow(title: "Run Checks Now", enabled: !model.busy) { model.request(Placement.healthRun) }
                PanelRow(title: "Open Pi-hole Admin", symbol: "arrow.up.right.square") {
                    model.request(Placement.openAdmin)
                    close()
                }
                PanelRow(title: "Restart the Stack", enabled: !model.busy) { model.request(Placement.restart) }
            } else if model.notInstalled && model.keptSource {
                PanelRow(title: "Install nice-dns", enabled: !model.busy) { model.request(Placement.install) }
            }
            Divider()
            PanelRow(title: "Open nice-dns", shortcut: "⌘O") { close(); openWindow() }
            PanelRow(title: "Quit", shortcut: "⌘Q") { close(); NSApp.terminate(nil) }
        }
        .padding(.bottom, 6)
        .frame(width: MenuPanel.width)
        .tint(Palette.accent)
    }

    /// The hero, compact. While an action runs: a spinner and its present-tense title.
    @ViewBuilder private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if model.busy {
                ProgressView().controlSize(.regular).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(runningTitle(model.paneID)).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !model.paneLatest.isEmpty {
                        Text(model.paneLatest).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            } else {
                let h = model.hero
                ZStack {
                    Circle().fill(Palette.tint(h.level.tone))
                    Image(systemName: h.level.heroSymbol).font(.system(size: 20)).foregroundStyle(Palette.icon(h.level.tone))
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !h.brief.isEmpty {
                        Text(h.brief).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
    }

    private var bridges: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tor bridges").font(.system(size: 13, weight: .medium))
                Text(bridgesCostLine).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Tor bridges", isOn: Binding(get: { model.bridgesOn }, set: { model.setBridges($0) }))
                .toggleStyle(.switch).labelsHidden().tint(Palette.switchOn)
                .disabled(model.busy)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

/// A row of the panel: a title, and a symbol or a shortcut at the end; the
/// whole row is the button, and it lights up under the pointer like a menu item.
struct PanelRow: View {
    let title: String
    var symbol: String?
    var shortcut: String?
    var enabled = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if let s = symbol { Image(systemName: s).foregroundStyle(.secondary) }
                if let k = shortcut { Text(k).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hover && enabled ? Color.primary.opacity(0.08) : .clear).padding(.horizontal, 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hover = $0 }
    }
}
