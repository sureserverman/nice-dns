// The pieces the three views share: the card, its rows, the status header
// (one component, drawn by Overview and Checks), the lookup path, the update
// row (one component, drawn by Overview and Setup) and the small helpers.
import AppKit
import NiceDNSKit
import SwiftUI

// MARK: Helpers

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// The absolute time of an epoch, for a tooltip: relative times are what the views say.
func absoluteTime(_ epoch: UInt64?) -> String {
    guard let e = epoch else { return "" }
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .medium
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(e)))
}

extension Tone {
    /// The symbol that says the tone besides its colour.
    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle"
        case .attention: return "exclamationmark.triangle"
        case .down: return "xmark.octagon"
        case .neutral: return "circle"
        }
    }

    var word: String {
        switch self {
        case .ok: return "passing"
        case .attention: return "needs attention"
        case .down: return "failing"
        case .neutral: return ""
        }
    }
}

// MARK: Card

/// A rounded card on the window's background, hairline-stroked.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
    }
}

/// The small caption over a card: "Stack", "Version", "Maintenance".
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A row of a card: a title with a subtitle under it, and the controls at the end.
struct ControlRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// A commit named in the subtitle, drawn in monospace.
    var commit: String?
    @ViewBuilder let trailing: Trailing

    private var subtitleText: Text? {
        guard let s = subtitle else { return nil }
        if let c = commit, let r = s.range(of: c) {
            return Text(String(s[..<r.lowerBound])) + Text(c).font(.system(size: 12, design: .monospaced)) + Text(String(s[r.upperBound...]))
        }
        return Text(s)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let t = subtitleText {
                    t.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }
}

extension ControlRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, commit: String? = nil) {
        self.init(title: title, subtitle: subtitle, commit: commit) { EmptyView() }
    }
}

/// A Run Checks / Install… style button in the brand green.
struct SuggestedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.accent.opacity(configuration.isPressed ? 0.8 : 1)))
            .opacity(enabled ? 1 : 0.5)
    }
}

// MARK: Status header

/// The status header: the hero on Overview, the count on Checks. One
/// component with one Run Checks button, so `health-run` has one place.
struct StatusHeader: View {
    @ObservedObject var model: AppModel
    enum Style {
        case hero(Hero)
        case checks(title: String, subtitle: String)
    }
    let style: Style

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            switch style {
            case .hero(let h):
                ZStack {
                    Circle().fill(Palette.tint(h.level.tone))
                    Image(systemName: h.level.heroSymbol)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(Palette.icon(h.level.tone))
                }
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(h.title).font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                    if !h.subtitle.isEmpty {
                        Text(h.subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 12)
                button(h.action)
            case .checks(let title, let subtitle):
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title.bold())
                    Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 12)
                button(.runChecks)
            }
        }
    }

    /// Run Checks, or Turn On while the schedule is stopped: the header's one button.
    @ViewBuilder private func button(_ action: HeroAction?) -> some View {
        switch action {
        case .runChecks?:
            Button("Run Checks") { model.request(Placement.healthRun) }.disabled(model.busy)
        case .turnOn?:
            // The automatic-checks switch's setter: `health-start` keeps its one place there.
            Button("Turn On") { model.setAuto(true) }.disabled(model.busy)
        case nil:
            EmptyView()
        }
    }
}

// MARK: Lookup path

struct HLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

struct PathNodeView: View {
    let node: PathNode
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Palette.nodeFill(node.tone))
                Circle().strokeBorder(Palette.nodeBorder(node.tone), lineWidth: 1.5)
                Image(systemName: node.id.symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.icon(node.tone))
            }
            .frame(width: 44, height: 44)
            Text(node.label).font(.system(size: 13, weight: .semibold))
            Text(node.caption)
                .font(.system(size: 12, weight: node.captionChanged ? .semibold : .regular))
                .foregroundStyle(node.captionChanged ? Palette.text(node.tone) : Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 96)
    }
}

/// "How a lookup travels": five nodes joined by lines, then one sentence.
struct PathCard: View {
    let path: LookupPath

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                Text("How a lookup travels")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(path.nodes.enumerated()), id: \.offset) { i, n in
                        if i > 0 {
                            HLine()
                                .stroke(Palette.nodeBorder(n.dashedIn ? .attention : n.tone),
                                        style: StrokeStyle(lineWidth: 2, dash: n.dashedIn ? [5, 4] : []))
                                .frame(maxWidth: .infinity, minHeight: 2, maxHeight: 2)
                                .padding(.top, 21)
                                .padding(.horizontal, 4)
                        }
                        PathNodeView(node: n)
                    }
                }
                Divider()
                Text(path.footer).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(path.sentence)
    }
}

// MARK: Update row

/// The update row: one component, drawn by Overview and by Setup, so
/// `update-check` and `update` have one place. No banner.
struct UpdateRowView: View {
    @ObservedObject var model: AppModel
    let status: Status

    var body: some View {
        let t = updateRowText(status, now: model.now)
        ControlRow(title: t.title, subtitle: t.subtitle, commit: t.commit) {
            switch t.button {
            case .check:
                Button("Check for Update") { model.request(Placement.updateCheck) }.disabled(model.busy)
            case .install:
                Button("Install…") { model.request(Placement.update) }
                    .buttonStyle(SuggestedButtonStyle()).disabled(model.busy)
            }
        }
        .help(absoluteTime(status.update.checkedAt))
    }
}

// MARK: Toast

/// What has no output: "Another action is running", "Could not open {url}".
struct Toast: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let n = model.notice {
            HStack(spacing: 10) {
                Text(n).font(.system(size: 13)).textSelection(.enabled)
                if let c = model.noticeCopy {
                    Button("Copy") { copyToPasteboard(c) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.bottom, 14)
            .padding(.horizontal, 20)
            .accessibilityAddTraits(.isStaticText)
        }
    }
}
