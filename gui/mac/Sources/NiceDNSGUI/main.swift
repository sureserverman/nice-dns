// nice-dns's macOS menu-bar app. With no argument it runs the menu-bar item
// and its window. The hooks exist for tests and proofs, as in the Linux GUI:
//   --check                 read the status once, print one line, exit 0/1/2
//   --screenshot <png>      draw the window with the current status into a PNG
//   --run-action <id> --exit  run one action with no dialog, print the pane, exit with its status
import AppKit
import NiceDNSKit
import SwiftUI

let usage = "usage: NiceDNSGUI [--check | --version | --screenshot <png> | --run-action <id> --exit]"

func version() -> String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
}

/// `--run-action <id> --exit`: run action `id` through the same ActionRun the
/// window uses, print the pane's text and exit with the action's status. It
/// needs no window, so it runs over ssh as well.
func runAction(_ id: String) -> Never {
    guard Actions.lookup(id)?.program != nil else {
        FileHandle.standardError.write("nice-dns-gui: '\(id)' is not an action that runs a command\n".data(using: .utf8)!)
        exit(2)
    }
    let run = ActionRun(id: id)
    run.start(environment: ProcessInfo.processInfo.environment, queue: .main) { r in
        guard r.end != nil else { return }
        print(r.paneText, terminator: "")
        exit(r.exitStatus.clamped)
    }
    dispatchMain()
}

/// `--screenshot <png>`: the window as it shows the status now, drawn by
/// AppKit into a bitmap (`bitmapImageRepForCachingDisplay`) from an
/// off-screen window: no Screen Recording permission, no window on screen.
func screenshot(_ path: String) -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let model = AppModel()
    model.show(AppModel.read(environment: model.environment))
    let size = NSRect(x: 0, y: 0, width: 720, height: 900)
    let host = NSHostingView(rootView: WindowView(model: model))
    host.frame = size
    let w = NSWindow(contentRect: size.offsetBy(dx: -10000, dy: -10000), styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = host
    w.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    host.display()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        FileHandle.standardError.write("nice-dns-gui: screenshot: no bitmap\n".data(using: .utf8)!)
        return 1
    }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write("nice-dns-gui: screenshot: \(error)\n".data(using: .utf8)!)
        return 1
    }
    w.orderOut(nil)
    return 0
}

extension Int32 {
    var clamped: Int32 { Swift.min(Swift.max(self, 0), 255) }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.count {
case 0:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
case 1 where args[0] == "--version":
    print("nice-dns-gui \(version())")
case 1 where args[0] == "--check":
    let (code, line) = statusCheck(environment: ProcessInfo.processInfo.environment)
    print(line)
    exit(code)
case 2 where args[0] == "--screenshot":
    exit(MainActor.assumeIsolated { screenshot(args[1]) })
case 3 where args[0] == "--run-action" && args[2] == "--exit":
    runAction(args[1])
default:
    FileHandle.standardError.write((usage + "\n").data(using: .utf8)!)
    exit(2)
}
