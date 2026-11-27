// The action bar and the output drawer. The bar exists only while an action
// runs and after it ends: a spinner, the present-tense title, the elapsed
// time and the command's latest line while it runs; the result, or "did not
// finish", after. The drawer holds the whole output (the command line, every
// line, the outcome) and opens by itself when an action fails.
import AppKit
import NiceDNSKit
import SwiftUI

struct ActionBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    detail
                }
                Spacer(minLength: 12)
                if model.outputOpen && !model.paneRows.isEmpty {
                    Button("Copy") { copyToPasteboard(model.paneText) }.buttonStyle(.borderless)
                }
                Button(model.outputOpen ? "Hide Output" : "Show Output") { model.outputOpen.toggle() }
                if !model.busy {
                    Button { model.dismissBar() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss")
                }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 58)
            if model.outputOpen {
                Divider()
                OutputDrawer(model: model)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var failed: Bool { !model.busy && !model.paneOK }

    private var title: String {
        if model.busy { return runningTitle(model.paneID) }
        return failed ? failedTitle(model.paneID) : model.paneResultTitle
    }

    @ViewBuilder private var icon: some View {
        if model.busy {
            ProgressView().controlSize(.small).frame(width: 22)
        } else if failed {
            Image(systemName: Tone.attention.symbol).font(.system(size: 19)).foregroundStyle(Palette.icon(.attention)).frame(width: 22)
                .accessibilityLabel("Did not finish")
        } else {
            Image(systemName: Tone.ok.symbol).font(.system(size: 19)).foregroundStyle(Palette.icon(.ok)).frame(width: 22)
                .accessibilityLabel("Finished")
        }
    }

    @ViewBuilder private var detail: some View {
        if model.busy {
            HStack(spacing: 6) {
                if let start = model.paneStarted {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        Text(elapsedText(Int(ctx.date.timeIntervalSince(start)))).monospacedDigit()
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if !model.paneLatest.isEmpty {
                    Text(model.paneLatest).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        } else {
            Text(failed ? model.paneDetail : "Finished in \(elapsedText(model.paneElapsed)) · \(model.paneResult)")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        }
    }
}

struct OutputDrawer: View {
    @ObservedObject var model: AppModel

    /// The whole output as one selectable text: stderr muted, the outcome in its tone.
    private var attributed: AttributedString {
        var out = AttributedString()
        for r in model.paneRows {
            var line = AttributedString(r.text + "\n")
            switch r.kind {
            case .command: line.foregroundColor = .secondary
            case .stdout: line.foregroundColor = .primary
            case .stderr: line.foregroundColor = Palette.stderr
            case .outcome: line.foregroundColor = Palette.text(model.paneOK ? .ok : .down)
            }
            out.append(line)
        }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(attributed)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                Color.clear.frame(height: 1).id("end")
            }
            .frame(maxHeight: 240)
            .background(Palette.inset)
            .onChange(of: model.paneRows.count) { _ in proxy.scrollTo("end") }
        }
        .accessibilityLabel("Output")
    }
}
