// The menu-bar item: a symbol that varies by level (so the state does not
// rest on colour alone), coloured from the status, that opens a panel (an
// NSPopover hosting MenuPanel), and the window the panel's Open nice-dns and
// every question or failure bring up.
import AppKit
import Combine
import NiceDNSKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let model = AppModel()
    private var item: NSStatusItem!
    private var popover: NSPopover!
    private var window: NSWindow?
    private var watch: Set<AnyCancellable> = []
    private var bundleWatch = BundleWatch()
    private var bundleTimer: Timer?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: MenuPanel(model: model, close: { [weak self] in self?.popover.performClose(nil) },
                                                           openWindow: { [weak self] in self?.openWindow() }))
        // The popover is as tall as the panel's content.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.drawGlyph() }
            .store(in: &watch)
        // A question asked from the panel needs the window to be asked in.
        model.$confirm
            .receive(on: RunLoop.main)
            .sink { [weak self] c in if c != nil { self?.openWindow() } }
            .store(in: &watch)
        // D4: an action started from the panel opens the window only when it
        // needs a question (above) or fails; the failed bar and its output are there.
        model.$failureCount
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.openWindow() }
            .store(in: &watch)
        drawGlyph()
        // An accessory app has no main menu to carry key equivalents: ⌘1, ⌘2 and
        // ⌘3 pick the window's views while it is the key window, ⌘O and ⌘Q act
        // while the panel is open.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handleKey(e) ?? e }
        model.startRefreshing()
        // An uninstall removes the bundle under the running app: quit then,
        // or the menu-bar item outlives the app (Stage 2 gate round 1).
        bundleTimer = Timer.scheduledTimer(withTimeInterval: AppModel.refreshInterval, repeats: true) { [weak self] _ in
            guard let self, let program = Bundle.main.executablePath else { return }
            let exists = FileManager.default.fileExists(atPath: program)
            if self.bundleWatch.tick(programExists: exists, busy: self.model.busy) { NSApp.terminate(nil) }
        }
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let ch = e.charactersIgnoringModifiers else { return e }
        if popover.isShown {
            switch ch {
            case "o": popover.performClose(nil); openWindow(); return nil
            case "q": popover.performClose(nil); NSApp.terminate(nil); return nil
            default: return e
            }
        }
        guard let n = Int(ch), (1...ViewTab.allCases.count).contains(n), window?.isKeyWindow == true, model.status != nil else { return e }
        model.view = ViewTab.allCases[n - 1]
        return nil
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

    /// The status item: the symbol of the level, in its colour; the hero's title is
    /// its tooltip and its accessibility description.
    private func drawGlyph() {
        let g = model.glyph
        let title = model.hero.title
        let config = NSImage.SymbolConfiguration(paletteColors: [NSColor(g.color)])
        let image = NSImage(systemSymbolName: model.menuSymbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
        item?.button?.image = image
        item?.button?.toolTip = title
        item?.button?.setAccessibilityLabel(title)
    }

    // MARK: The panel

    @objc private func togglePanel(_ sender: Any?) {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Fresh status on open, so the panel is not up to 5 s old.
            model.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: The window

    @objc func openWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "nice-dns"
            w.contentMinSize = NSSize(width: 680, height: 560)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WindowView(model: model))
            w.center()
            w.delegate = self
            window = w
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing only hides it; the menu-bar item keeps running.
        sender.orderOut(nil)
        return false
    }
}
