// Setup: what is installed, and how to change it. The stack's two
// selectors, the version and the update row, and maintenance (Uninstall is
// the last row on purpose).
import AppKit
import NiceDNSKit
import SwiftUI

struct SetupView: View {
    @ObservedObject var model: AppModel
    let status: Status

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Stack")
                Card {
                    ForEach(Array(StackChoice.all.enumerated()), id: \.element.kind) { i, c in
                        if i > 0 { Divider() }
                        ChoiceRow(model: model, choice: c)
                    }
                    Divider()
                    Text(StackChoice.footer)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Version")
                Card {
                    let v = versionRow(status)
                    ControlRow(title: v.title, subtitle: v.subtitle) {
                        Button("Copy Build Details") { copyToPasteboard(buildDetails(status)) }.buttonStyle(.borderless)
                    }
                    .help(generationDate(status.install.generation) == nil ? "" : "Generation \(status.install.generation ?? "")")
                    Divider()
                    UpdateRowView(model: model, status: status)
                    if helperMissing(status) {
                        Divider()
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: Tone.attention.symbol).foregroundStyle(Palette.icon(.attention)).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Root helper is missing").font(.system(size: 14, weight: .medium))
                                Text("Actions that need root will ask in a terminal.").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 13)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Maintenance")
                Card {
                    ControlRow(title: "Restart the stack", subtitle: "Restarts every container. Tor reconnects in about a minute.") {
                        Button("Restart") { model.request(Placement.restart) }.disabled(model.busy)
                    }
                    Divider()
                    ControlRow(title: "Reinstall", subtitle: "Rebuild with another branch, proxy or Pi-hole image.") {
                        Button("Reinstall…") { model.request(Placement.reinstall) }.disabled(model.busy)
                    }
                    Divider()
                    ControlRow(title: "Uninstall nice-dns", subtitle: "Gives DNS back to the system, then removes the stack and this app.") {
                        // A text button in the destructive colour, not filled: it is the last row on purpose.
                        Button("Uninstall…") { model.request(Placement.uninstall) }
                            .buttonStyle(.borderless).foregroundStyle(Palette.destructive).disabled(model.busy)
                    }
                }
            }
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
        ControlRow(title: choice.title, subtitle: choice.subtitle) {
            if let shown {
                Picker(choice.title, selection: Binding(get: { shown }, set: { model.pick(choice, $0) })) {
                    ForEach(choice.choices, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(model.busy)
            } else {
                // A segmented control has no place for a third value: the unknown one is said in words.
                Text("unknown").foregroundStyle(.secondary).accessibilityLabel("\(choice.title): unknown")
            }
        }
    }
}
