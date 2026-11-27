// Checks: what exactly was checked, and what the controller did. The
// status header, the automatic-checks switch, the checks in three groups
// (a group with a failing check starts open) and the automatic repairs.
import AppKit
import NiceDNSKit
import SwiftUI

struct ChecksView: View {
    @ObservedObject var model: AppModel
    let status: Status

    var body: some View {
        let level = Level.of(status)
        // Old results are dimmed, as the status header says it in words.
        let old = level == .stale || level == .waiting
        VStack(alignment: .leading, spacing: 20) {
            StatusHeader(model: model, style: .checks(title: checksTitle(status), subtitle: checksSubtitle(status, now: model.now)))
                .help(absoluteTime(lastPassEpoch))
            Card {
                ControlRow(title: "Check and repair automatically", subtitle: autoChecksSubtitle(status)) {
                    Toggle("Check and repair automatically", isOn: Binding(get: { model.autoOn }, set: { model.setAuto($0) }))
                        .toggleStyle(.switch).labelsHidden().tint(Palette.switchOn)
                        .disabled(model.busy)
                }
            }
            Card {
                let groups = checkGroups(status)
                ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                    if i > 0 { Divider() }
                    GroupView(model: model, group: g)
                }
            }
            .opacity(old ? 0.5 : 1)
            repairs
        }
    }

    private var lastPassEpoch: UInt64? {
        if case .at(let e)? = status.controller.lastPass { return e }
        return nil
    }

    private var repairs: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Automatic repairs")
                Spacer()
                Button("Show Failures") { model.request(Placement.failures) }
                    .buttonStyle(.link).foregroundStyle(Palette.accentText).disabled(model.busy)
            }
            Card {
                let rows = repairRows(status, now: model.now)
                if rows.isEmpty {
                    Text("No repairs yet.").font(.system(size: 13)).foregroundStyle(.secondary).padding(18)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    if i > 0 { Divider() }
                    HStack {
                        Text(r.text).font(.system(size: 14))
                        Spacer(minLength: 12)
                        Text(r.ago).font(.system(size: 13)).foregroundStyle(.secondary).help(absoluteTime(r.epoch))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                }
            }
        }
    }
}

/// The disclosure chevron, in a column of its own so it centres on the title.
struct Chevron: View {
    let open: Bool
    var body: some View {
        Image(systemName: open ? "chevron.down" : "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 14)
    }
}

/// One group: a chevron column, title and subtitle, and its count at the end,
/// aligned to the card's row padding; opened, its rows.
struct GroupView: View {
    @ObservedObject var model: AppModel
    let group: CheckGroupModel

    private var open: Bool { model.groupOpen[group.id] ?? group.startsExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.groupOpen[group.id] = !open } label: {
                HStack(alignment: .center, spacing: 10) {
                    Chevron(open: open)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title).font(.system(size: 14, weight: .medium))
                        Text(group.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    // The words carry the count besides the colour.
                    Text(group.summary).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text(group.summaryTone))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.rows, id: \.id) { r in
                        Divider()
                        CheckRowView(model: model, row: r)
                    }
                }
                .padding(.leading, 42)
                .padding(.trailing, 18)
                .padding(.bottom, 6)
            }
        }
    }
}

/// A check: its friendly name and a short value; failing, the level icon and
/// the headline. Opened, the raw record in monospace.
struct CheckRowView: View {
    @ObservedObject var model: AppModel
    let row: CheckRowModel
    private var open: Bool { model.rowOpen.contains(row.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { if open { model.rowOpen.remove(row.id) } else { model.rowOpen.insert(row.id) } } label: {
                HStack(alignment: .center, spacing: 8) {
                    Chevron(open: open)
                    if !row.healthy {
                        Image(systemName: row.tone.symbol).foregroundStyle(Palette.icon(row.tone))
                            .accessibilityLabel(row.tone == .down ? "Not working" : "Needs attention")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(row.name).font(.system(size: 14))
                            if row.inUse {
                                Text("In use").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Palette.text(.ok))
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(Capsule().fill(Palette.tint(.ok)))
                            }
                        }
                        if let h = row.headline {
                            Text(h).font(.system(size: 12)).foregroundStyle(Palette.text(row.tone))
                        }
                    }
                    Spacer(minLength: 8)
                    if let v = row.value {
                        Text(v).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the raw record of this check")
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.record).font(.system(size: 12, design: .monospaced))
                    Text(row.reason).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.inset))
                .padding(.bottom, 8)
            }
        }
    }
}
