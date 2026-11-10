// Whether the running app should quit because an uninstall removed it.
// AppKit-free, so KitCheck tests it.

/// Fed once per status tick: the app quits once its program has been missing
/// on two ticks running and no action runs. One tick is not enough (a
/// reinstall renames the bundle aside for a moment), and an action keeps it
/// (an uninstall run from the app removes the bundle under itself; the app
/// quits after it has shown the result).
public struct BundleWatch {
    private var missing = 0

    public init() {}

    /// True when the app should quit now.
    public mutating func tick(programExists: Bool, busy: Bool) -> Bool {
        // Counted only while no action runs: the result of an uninstall run
        // from the app stays on screen for a tick before it quits.
        if programExists || busy { missing = 0; return false }
        missing += 1
        return missing >= 2
    }
}
