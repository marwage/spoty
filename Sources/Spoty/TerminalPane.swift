import AppKit
import SwiftTerm
import SwiftUI

/// Signals readiness only once the view is in a window *and* has a real size.
///
/// This has to hang off `layout()` rather than `viewDidMoveToWindow()`: a SwiftUI-hosted
/// NSView still has zero bounds when it is first added to the window, and starting the
/// child there means `getWindowSize()` reports SwiftTerm's 80x25 default, so the TUI's
/// Kitty-protocol cover art gets scaled against the wrong cell size.
final class HostedTerminalView: LocalProcessTerminalView {
    var onReady: (() -> Void)?
    private var didSignalReady = false

    override func layout() {
        super.layout()
        guard !didSignalReady, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        didSignalReady = true
        DispatchQueue.main.async { [weak self] in
            self?.onReady?()
        }
    }
}

struct TerminalPane: NSViewRepresentable {
    let process: PlayerProcess

    func makeNSView(context: Context) -> HostedTerminalView {
        let terminal = HostedTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        terminal.font = NSFont(name: "SF Mono", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = Theme.foreground
        terminal.caretColor = Theme.caret
        terminal.selectedTextBackgroundColor = Theme.selection
        terminal.installColors(Theme.ansiPalette)

        process.attach(to: terminal)
        terminal.onReady = { process.startIfNeeded() }
        return terminal
    }

    func updateNSView(_ terminal: HostedTerminalView, context: Context) {}
}

enum Theme {
    static let foreground = NSColor(srgbRed: 0.973, green: 0.973, blue: 0.949, alpha: 1)
    static let caret = NSColor(srgbRed: 0.973, green: 0.973, blue: 0.941, alpha: 1)
    static let selection = NSColor(srgbRed: 0.267, green: 0.278, blue: 0.353, alpha: 1)

    /// The 16 ANSI colours the TUI falls back to for anything it doesn't paint with an
    /// explicit truecolor escape. Index 0 is pinned to the theme's pitch-black background
    /// so an ANSI-black cell can't show up as a lighter patch. `installColors` takes
    /// exactly these 16; 16-255 are derived by SwiftTerm.
    ///
    /// Computed rather than stored: SwiftTerm's Color is a class with mutable components,
    /// so a static array of them would be shared mutable state.
    static var ansiPalette: [SwiftTerm.Color] {[
        Color(red8: 0x00, green8: 0x00, blue8: 0x00),  // black
        Color(red8: 0xFF, green8: 0x55, blue8: 0x55),  // red
        Color(red8: 0x50, green8: 0xFA, blue8: 0x7B),  // green
        Color(red8: 0xF1, green8: 0xFA, blue8: 0x8C),  // yellow
        Color(red8: 0xBD, green8: 0x93, blue8: 0xF9),  // blue
        Color(red8: 0xFF, green8: 0x79, blue8: 0xC6),  // magenta
        Color(red8: 0x8B, green8: 0xE9, blue8: 0xFD),  // cyan
        Color(red8: 0xF8, green8: 0xF8, blue8: 0xF2),  // white
        Color(red8: 0x62, green8: 0x72, blue8: 0xA4),  // bright black
        Color(red8: 0xFF, green8: 0x6E, blue8: 0x6E),  // bright red
        Color(red8: 0x69, green8: 0xFF, blue8: 0x94),  // bright green
        Color(red8: 0xFF, green8: 0xFF, blue8: 0xA5),  // bright yellow
        Color(red8: 0xD6, green8: 0xAC, blue8: 0xFF),  // bright blue
        Color(red8: 0xFF, green8: 0x92, blue8: 0xDF),  // bright magenta
        Color(red8: 0xA4, green8: 0xFF, blue8: 0xFF),  // bright cyan
        Color(red8: 0xFF, green8: 0xFF, blue8: 0xFF),  // bright white
    ]}
}
