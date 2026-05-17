import XCTest
import AppKit
@testable import SwiftTerm

/// Compile-only API-surface smoke test. Mirrors the API surface that
/// `kellyredding/Galactic` consumes from this fork — the SwiftTerm
/// methods, properties, override capabilities, and Galactic-added
/// members (e.g., `galacticBoldForegroundColor`) that Galactic's
/// `SwiftTermBackend`, `GalacticSwiftTermView`, and
/// `SwiftTermScrollbackRenderer` types depend on.
///
/// If this compiles, Galactic will compile against this fork. No
/// runtime behavior is tested — that's Galactic's job via its own
/// smoke test against a real session.
///
/// This test runs from a sub-package (`GalacticApiSmoke/`) at the fork
/// root that depends on the parent package via relative path. It's
/// committed BEFORE the upstream import in the 4-commit `main`
/// structure, so the sub-package's `swift test` only succeeds against
/// commit 4 (where upstream + patches are both present). See
/// MAINTAINING.md for the structure.
///
/// Every reference here corresponds to a real consumption point in
/// Galactic's `SwiftTermBackend.swift`, `GalacticSwiftTermView.swift`,
/// or `SwiftTermScrollbackRenderer.swift`. When Galactic gains a new
/// dependency on SwiftTerm API, add a corresponding reference here.
final class GalacticApiSmokeTests: XCTestCase {

    // MARK: - Subclass override capability
    //
    // Mirrors GalacticSwiftTermView's subclassing pattern. If any of
    // these overrides isn't permitted (target method isn't `open` in
    // the superclass), this class fails to compile.

    final class TestSubclass: LocalProcessTerminalView {
        var onBell: (() -> Void)?
        var onScrollUp: ((NSEvent) -> Bool)?
        var displayPaused = false
        var suppressFocusEvents = false

        public override func scrollWheel(with event: NSEvent) {
            if event.deltaY > 0, let cb = onScrollUp, cb(event) { return }
            super.scrollWheel(with: event)
        }
        public override func becomeFirstResponder() -> Bool {
            return super.becomeFirstResponder()
        }
        public override func resignFirstResponder() -> Bool {
            return super.resignFirstResponder()
        }
        public override func bell(source: Terminal) {
            onBell?()
        }
        public override func setNeedsDisplay(_ invalidRect: NSRect) {
            if displayPaused { return }
            super.setNeedsDisplay(invalidRect)
        }
    }

    // MARK: - Process delegate

    /// Mirrors SwiftTermBackend's conformance to LocalProcessTerminalViewDelegate.
    final class TestDelegate: NSObject, LocalProcessTerminalViewDelegate {
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }

    // MARK: - API surface

    /// Exercises every public member Galactic's `SwiftTermBackend`
    /// reads or writes. If a visibility regresses (Galactic patch
    /// dropped) or upstream renames a member, this stops compiling.
    func testApiSurface() {
        let view = TestSubclass(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let delegate = TestDelegate()

        // SwiftTerm value types Galactic constructs directly.
        _ = SwiftTerm.Color(red: 0, green: 0, blue: 0)
        let _: SwiftTerm.CursorStyle = .steadyBlock
        let _: SwiftTerm.CursorStyle = .blinkBlock
        let _: SwiftTerm.CursorStyle = .steadyUnderline
        let _: SwiftTerm.CursorStyle = .blinkUnderline
        let _: SwiftTerm.CursorStyle = .steadyBar
        let _: SwiftTerm.CursorStyle = .blinkBar

        // Process lifecycle.
        view.processDelegate = delegate
        view.startProcess(
            executable: "/bin/zsh",
            args: [],
            environment: [],
            execName: "zsh",
            currentDirectory: "/tmp"
        )
        _ = view.process.shellPid

        // IO.
        view.send([UInt8](repeating: 0x41, count: 5))
        view.send(txt: "hello")
        view.feed(text: "hello")

        // Terminal state (visibility opens — Galactic patch makes these public).
        _ = view.terminal.bracketedPasteMode
        _ = view.terminal.userScrolling
        view.terminal.changeHistorySize(10000)
        view.terminal.setCursorStyle(.steadyBlock)

        // Buffer access (visibility opens).
        let displayBuffer = view.terminal.displayBuffer
        _ = displayBuffer.yBase
        _ = displayBuffer.yDisp
        _ = displayBuffer.cols
        _ = displayBuffer.rows
        let _: Buffer = view.terminal.buffer

        // Galactic-added properties (must survive every bump).
        view.galacticBoldForegroundColor = NSColor.white

        // Galactic visibility opens on the view itself.
        _ = view.cellDimension
        _ = view.caretView
        _ = view.selection

        // Color application.
        view.nativeForegroundColor = NSColor.white
        view.nativeBackgroundColor = NSColor.black
        view.installColors([SwiftTerm.Color(red: 0, green: 0, blue: 0)])

        // Font.
        let _: NSFont = view.font
        view.font = NSFont.systemFont(ofSize: 12)

        // Selection (Galactic added adjustForTrimmedLines).
        view.selection.selectNone()
        view.selection.adjustForTrimmedLines(0)
        _ = view.selection.active

        // Caret (visibility open on caretView allows direct access).
        view.caretView.isHidden = false
    }

    // MARK: - Snapshot capability

    /// Verifies the buffer-snapshot pattern Galactic's
    /// `SwiftTermScrollbackSnapshot` relies on. The snapshot must be
    /// a deep copy that survives mutations to the live buffer.
    func testSnapshotApi() {
        let view = TestSubclass(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        let snapshot = view.terminal.snapshotBuffer(view.terminal.buffer)
        _ = snapshot.cols
        _ = snapshot.rows
        _ = snapshot.yDisp
        _ = snapshot.yBase
        _ = snapshot.lines

        // Snapshot-buffer subscript access (used by the HTML renderer).
        if snapshot.lines.count > 0 {
            let line: BufferLine = snapshot.lines[0]
            _ = line
        }
    }

    // MARK: - Galactic-specific additions

    /// Verifies Galactic-added types and members exist at the right
    /// visibility for cross-module use.
    func testGalacticAdditions() {
        // GalacticScroller (Galactic-added subclass) is instantiable.
        let scroller = GalacticScroller(frame: .zero)
        _ = scroller

        // Galactic-added NSAttributedString.Key for bold-state plumbing.
        let _: NSAttributedString.Key = .galacticBold

        // Galactic-added SelectionService method already covered in
        // testApiSurface — listed here for documentation:
        //   view.selection.adjustForTrimmedLines(_:)
    }

    // MARK: - Palette strategy contract

    /// The 256-color palette strategy upstream introduced in #519
    /// (commit 36642aa). Upstream's default is `.base16Lab`, which
    /// interpolates 256-color codes through the theme background in
    /// LAB color space — producing muted, theme-cohesive colors that
    /// visually dim Claude's heavy use of 256-color tool labels and
    /// gray separators. The Galactic patch overrides the default in
    /// `TerminalOptions.default` to `.xterm`, restoring the historical
    /// fixed-RGB xterm cube + grayscale ramp.
    ///
    /// This test verifies the API surface stays stable across bumps —
    /// if upstream renames the enum, removes a case, or removes the
    /// property from TerminalOptions, this stops compiling and the
    /// Galactic patch needs to be revisited.
    func testAnsi256PaletteStrategyApi() {
        // Enum cases exist.
        let _: Ansi256PaletteStrategy = .xterm
        let _: Ansi256PaletteStrategy = .base16Lab

        // Property exists on TerminalOptions and is read/write.
        var options = TerminalOptions.default
        _ = options.ansi256PaletteStrategy
        options.ansi256PaletteStrategy = .xterm
    }
}
