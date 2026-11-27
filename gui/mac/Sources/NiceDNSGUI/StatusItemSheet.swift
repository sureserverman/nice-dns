// Evidence for the menu-bar item: its symbol and colour for every level, as
// the status item draws them (MenuBar.drawGlyph). Drawn only by
// `--screenshot-status-items`.
import AppKit
import NiceDNSKit
import SwiftUI

struct StatusItemSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Level.allCases, id: \.self) { l in
                HStack(spacing: 14) {
                    Image(systemName: l.menuSymbol)
                        .font(.system(size: 22))
                        .foregroundStyle(l.glyph.color)
                        .frame(width: 34)
                    Text("\(l.rawValue): \(l.menuSymbol), \(l.glyph.rawValue)").font(.system(size: 13, design: .monospaced))
                }
            }
            HStack(spacing: 14) {
                Image(systemName: Level.loadingMenuSymbol).font(.system(size: 22)).foregroundStyle(Glyph.grey.color).frame(width: 34)
                Text("loading: \(Level.loadingMenuSymbol), grey").font(.system(size: 13, design: .monospaced))
            }
        }
        .padding(20)
    }
}
