// The menu-bar item: a glyph coloured from the status, and a menu with the
// actions, the bridges switch, Open window and Quit.
import AppKit
import Combine
import NiceDNSKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let model = AppModel()
    private var item: NSStatusItem!
    private var window: NSWindow?
    private var watch: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.drawGlyph() }
            .store(in: &watch)
        // A question asked from the menu needs the window to be asked in.
        model.$confirm
            .receive(on: RunLoop.main)
            .sink { [weak self] c in if c != nil { self?.openWindow() } }
            .store(in: &watch)
        drawGlyph()
        model.startRefreshing()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting mid-action would leave the command with no one reading its
    /// output, midway through (say) a reinstall: refused once, with a notice.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.busy else { return .terminateNow }
        if let t = model.quitAsked, Date().timeIntervalSince(t) < 10 { return .terminateNow }
        model.quitAsked = Date()
        openWindow()
        // Quitting closes the command's output, so it is cut off midway: said plainly.
        model.say("An action is running. Quitting now stops it midway; quit again within 10 s to quit anyway")
        return .terminateCancel
    }

    private func drawGlyph() {
        let g = model.glyph
        let config = NSImage.SymbolConfiguration(paletteColors: [NSColor(g.color)])
        let image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "nice-dns: \(g.rawValue)")?
            .withSymbolConfiguration(config)
        item?.button?.image = image
        item?.button?.toolTip = "nice-dns: \(summary)"
    }

    private var summary: String {
        switch model.page {
        case .loading: return "reading the status"
        case .missing(let p): return "command not found at \(p)"
        case .status(.notInstalled): return "not installed"
        case .status(.error(let m)): return m
        case .status(.unreadable): return "a file cannot be read"
        case .status(.installed(let s)):
            let stale = s.controller.stale.map { "\($0)" } ?? "unknown"
            return "controller \(s.controller.verdict ?? "unknown"), \(stale)"
        }
    }

    // MARK: The menu, built each time it opens

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: "nice-dns: \(summary)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if model.status?.update.result == .available {
            menu.addItem(entry("A different version is available…", "update"))
        }
        menu.addItem(.separator())
        if model.installed {
            let b = entry("Tor bridges", model.bridgesOn ? "bridges-off" : "bridges-on")
            b.state = model.bridgesOn ? .on : .off
            menu.addItem(b)
        }
        if model.installed {
            // A described stack: every action that runs a command but Install
            // (the not-installed page's) and the update (offered above).
            for a in Actions.all where a.program != nil && !a.id.hasPrefix("bridges-") && a.id != "update" && a.id != "install" {
                menu.addItem(entry(a.label + (a.needsConfirm ? "…" : ""), a.id))
            }
        } else if model.notInstalled && model.keptSource, let a = Actions.lookup("install") {
            menu.addItem(entry(a.label, a.id))
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open window", action: #selector(openWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit nice-dns", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func entry(_ title: String, _ id: String) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: model.busy ? nil : #selector(choose(_:)), keyEquivalent: "")
        m.target = self
        m.representedObject = id
        return m
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // The output is in the window: show it for every action.
        openWindow()
        model.request(id)
    }

    // MARK: The window

    @objc func openWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "nice-dns"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WindowView(model: model))
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing only hides it; the menu-bar item keeps running.
        sender.orderOut(nil)
        return false
    }
}
