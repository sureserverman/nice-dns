// Overview: is my DNS protected right now? The status header, the lookup
// path, the attention list (only when something is wrong), the everyday
// controls and, at level ok, the links to Checks.
import AppKit
import NiceDNSKit
import SwiftUI

struct OverviewView: View {
    @ObservedObject var model: AppModel
    let status: Status

    var body: some View {
        let level = Level.of(status)
        let attention = attentionRows(status)
        VStack(alignment: .leading, spacing: 20) {
            if !status.unreadable.isEmpty { unreadable }
            StatusHeader(model: model, style: .hero(model.hero))
            PathCard(path: lookupPath(status))
            if !attention.isEmpty { AttentionCard(model: model, rows: attention, total: status.obs.count) }
            controls
            if level == .ok { links }
        }
    }

    private var unreadable: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Some files could not be read").font(.system(size: 14, weight: .semibold))
                ForEach(status.unreadable, id: \.group) { u in
                    Label("\(u.group): \(u.reason)", systemImage: Tone.attention.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text(.attention))
                        .textSelection(.enabled)
                }
            }
            .padding(18)
        }
    }

    private var controls: some View {
        Card {
            ControlRow(title: "Tor bridges", subtitle: bridgesSubtitle(on: model.bridgesOn)) {
                Toggle("Tor bridges", isOn: Binding(get: { model.bridgesOn }, set: { model.setBridges($0) }))
                    .toggleStyle(.switch).labelsHidden().tint(Palette.switchOn)
                    .disabled(model.busy)
            }
            .help(bridgesTooltip(status, now: model.now))
            Divider()
            ControlRow(title: "Pi-hole admin", subtitle: adminSubtitle(status)) {
                HStack(spacing: 8) {
                    Button("Show Password File") { model.request(Placement.showPasswordPath) }
                        .buttonStyle(FlatButtonStyle()).disabled(model.busy)
                    Button { model.request(Placement.openAdmin) } label: {
                        Label("Open", systemImage: "arrow.up.right.square").labelStyle(TrailingIconLabelStyle())
                    }
                    .disabled(model.busy)
                    .accessibilityLabel("Open the Pi-hole admin page")
                }
            }
            Divider()
            UpdateRowView(model: model, status: status)
        }
    }

    /// Shown only at level ok: the passing count and the newest repair, each opening Checks.
    private var links: some View {
        let l = overviewLinks(status, now: model.now)
        return Card {
            LinkRow(symbol: Tone.ok.symbol, tone: .ok, text: l.passing) { model.view = .checks }
            if let r = l.repair {
                Divider()
                LinkRow(symbol: "wrench.and.screwdriver", tone: .neutral, text: r) { model.view = .checks }
            }
        }
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.title; configuration.icon }
    }
}

struct LinkRow: View {
    let symbol: String
    let tone: Tone
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(Palette.icon(tone))
                Text(text).font(.system(size: 14)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Checks")
    }
}

/// The failing checks: icon by level, the headline from the check table and
/// the raw reason under it, whole and selectable.
struct AttentionCard: View {
    @ObservedObject var model: AppModel
    let rows: [AttentionRow]
    let total: Int

    var body: some View {
        Card {
            HStack {
                Text("\(rows.count) \(rows.count == 1 ? "check needs" : "checks need") attention")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.view = .checks } label: {
                    HStack(spacing: 4) { Text("All \(total) Checks"); Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)) }
                        .foregroundStyle(Palette.accentText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: r.tone.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.icon(r.tone))
                        .frame(width: 20)
                        .accessibilityLabel(r.tone == .down ? "Not working" : "Needs attention")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.headline).font(.system(size: 14, weight: .medium))
                        Text(r.reason)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }
        }
    }
}
