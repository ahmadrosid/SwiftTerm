#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct SelectionDragTests {
    private func makeView(fontSize: CGFloat = 14) -> (TerminalView, NSWindow) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 480, height: 240),
                                font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                options: TerminalOptions(cols: 40, rows: 10, scrollback: 100))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.selectionDragInput = { (1, []) }
        view.withTerminal { terminal in
            for _ in 0..<80 { terminal.feed(text: "0123456789 abc def\r\n") }
        }
        view.scrollTo(row: 20)
        return (view, window)
    }

    private func point(_ view: TerminalView, col: Int, row: Int) -> CGPoint {
        CGPoint(x: (CGFloat(col) + 0.5) * view.cellDimension.width,
                y: view.bounds.maxY - (CGFloat(row) + 0.5) * view.cellDimension.height)
    }

    private func mouse(_ view: TerminalView, _ type: NSEvent.EventType, at point: CGPoint,
                       flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                                      modifierFlags: flags, timestamp: 0,
                                      windowNumber: view.window!.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: clicks, pressure: 1)!
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }

    @Test func firstDragUsesPressLocation() {
        let (view, window) = makeView()
        defer { window.close() }
        for (start, end) in [(2, 6), (6, 2)] {
            mouse(view, .leftMouseDown, at: point(view, col: start, row: 3))
            mouse(view, .leftMouseDragged, at: point(view, col: end, row: 3))
            view.withTerminal { _ in
                #expect(view.selection.start.col == start)
                #expect(view.selection.end.col == end)
                #expect(view.selection.getSelectedText() == "2345")
            }
            mouse(view, .leftMouseUp, at: point(view, col: end, row: 3))
        }
    }

    @Test func topRowDoesNotStartScrolling() {
        let (view, window) = makeView()
        defer { window.close() }
        mouse(view, .leftMouseDown, at: point(view, col: 2, row: 3))
        mouse(view, .leftMouseDragged, at: point(view, col: 6, row: 0))
        let before = view.withTerminal { $0.displayBuffer.yDisp }
        #expect(!view.selectionAutoScrollActive)
        #expect(view.withTerminal { $0.displayBuffer.yDisp } == before)
        mouse(view, .leftMouseUp, at: point(view, col: 6, row: 0))
    }

    @Test func clickAndCrossRowSelection() {
        let (view, window) = makeView()
        defer { window.close() }
        mouse(view, .leftMouseDown, at: point(view, col: 2, row: 3))
        #expect(!view.withTerminal { _ in view.selection.active })
        mouse(view, .leftMouseUp, at: point(view, col: 2, row: 3))
        #expect(!view.withTerminal { _ in view.selection.active })
        mouse(view, .leftMouseDown, at: point(view, col: 2, row: 3))
        mouse(view, .leftMouseDragged, at: point(view, col: 6, row: 4))
        #expect(view.withTerminal { _ in view.selection.getSelectedText() } == "23456789 abc def\n012345")
    }

    @Test func scrollDistanceUsesRowsAtDifferentFontSizes() {
        for size: CGFloat in [10, 20] {
            let (view, window) = makeView(fontSize: size)
            defer { window.close() }
            let interior = point(view, col: 2, row: 3)
            let stationary = [interior, CGPoint(x: 20, y: view.bounds.maxY),
                              CGPoint(x: 20, y: view.bounds.minY),
                              CGPoint(x: -20, y: interior.y),
                              CGPoint(x: view.bounds.maxX + 20, y: interior.y)]
            for target in stationary {
                mouse(view, .leftMouseDown, at: interior)
                mouse(view, .leftMouseDragged, at: target)
                #expect(!view.selectionAutoScrollActive)
                #expect(view.withTerminal { $0.displayBuffer.yDisp } == 20)
            }
            for distance in [CGFloat(1), view.cellDimension.height * 7] {
                let speed = distance == 1 ? 1 : 10
                for up in [true, false] {
                    view.scrollTo(row: 20)
                    mouse(view, .leftMouseDown, at: interior)
                    let outside = CGPoint(x: 20, y: up ? view.bounds.maxY + distance : -distance)
                    mouse(view, .leftMouseDragged, at: outside)
                    #expect(view.selectionAutoScrollActive)
                    view.scrollingTimerElapsed()
                    #expect(view.withTerminal { $0.displayBuffer.yDisp } == 20 + (up ? -speed : speed))
                    mouse(view, .leftMouseDragged, at: interior)
                    #expect(!view.selectionAutoScrollActive)
                    mouse(view, .leftMouseUp, at: interior)
                }
            }
        }
    }

    @Test func anchorSurvivesTrimmingButNotRecycling() {
        for trim in [false, true] {
            let (view, window) = makeView()
            defer { window.close() }
            // Capture a line near the bottom so a few trims retain it.
            view.scrollTo(row: 60)
            let press = point(view, col: 2, row: 3)
            let oldRow = view.calculateMouseHit(at: press).grid.row
            let line = view.withTerminal { $0.displayBuffer.lines[oldRow] }
            mouse(view, .leftMouseDown, at: press)
            view.withTerminal { terminal in
                for _ in 0..<(trim ? 160 : 40) { terminal.feed(text: "new output\r\n") }
            }
            let newRow = view.withTerminal { $0.displayBuffer.absoluteRow(of: line) }
            mouse(view, .leftMouseDragged, at: point(view, col: 6, row: 3))
            if trim {
                #expect(!view.withTerminal { _ in view.selection.active })
                mouse(view, .leftMouseDragged, at: point(view, col: 7, row: 3))
                #expect(!view.withTerminal { _ in view.selection.active })
            } else {
                #expect(newRow != oldRow)
                #expect(view.withTerminal { _ in view.selection.start.row } == newRow)
                #expect(view.withTerminal { _ in view.selection.getSelectedText() } == "2345")
            }
        }
    }

    @Test func canceledGesturesDoNotScrollOrRestart() {
        for reason in ["release", "clear", "buffer", "resize", "detach", "shutdown", "hidden"] {
            let (view, window) = makeView()
            defer { window.close() }
            let inside = point(view, col: 2, row: 3)
            let outside = CGPoint(x: 20, y: view.bounds.maxY + 1)
            mouse(view, .leftMouseDown, at: inside)
            mouse(view, .leftMouseDragged, at: outside)
            #expect(view.selectionAutoScrollActive)
            switch reason {
            case "release": view.selectionDragInput = { (0, []) }
            case "clear": view.withTerminal { _ in view.selection.selectNone() }
            case "buffer": view.withTerminal { $0.feed(text: "\u{1b}[?1049h") }
            case "resize": view.frame.size.width += 40
            case "detach": view.removeFromSuperview()
            case "shutdown": _ = view.updateUiClosed()
            default: view.isHidden = true
            }
            let before = view.withTerminal { $0.displayBuffer.yDisp }
            view.scrollingTimerElapsed()
            #expect(!view.selectionAutoScrollActive)
            #expect(view.withTerminal { $0.displayBuffer.yDisp } == before)
            if reason == "clear" {
                mouse(view, .leftMouseDragged, at: inside)
                #expect(!view.withTerminal { _ in view.selection.active })
            }
        }
    }

    @Test func pendingAnchorCancelsOnBufferSwitchOrResize() {
        for resize in [false, true] {
            let (view, window) = makeView()
            defer { window.close() }
            mouse(view, .leftMouseDown, at: point(view, col: 2, row: 3))
            if resize { view.frame.size.width += 40 }
            else { view.withTerminal { $0.feed(text: "\u{1b}[?1049h") } }
            mouse(view, .leftMouseDragged, at: point(view, col: 6, row: 3))
            #expect(!view.withTerminal { _ in view.selection.active })
        }
    }

    @Test func releasingShiftStopsStationaryBypassDrag() {
        let (view, window) = makeView()
        defer { window.close() }
        view.withTerminal { $0.feed(text: "\u{1b}[?1002h") }
        view.selectionDragInput = { (1, .shift) }
        mouse(view, .leftMouseDown, at: point(view, col: 2, row: 3), flags: .shift)
        mouse(view, .leftMouseDragged, at: CGPoint(x: 20, y: view.bounds.maxY + 1), flags: .shift)
        #expect(view.selectionAutoScrollActive)
        view.scrollingTimerElapsed()
        let before = view.withTerminal { $0.displayBuffer.yDisp }
        view.selectionDragInput = { (1, []) }
        view.scrollingTimerElapsed()
        #expect(!view.selectionAutoScrollActive)
        #expect(view.withTerminal { $0.displayBuffer.yDisp } == before)
    }

    @Test func timerContinuesWithoutDragEventsAndStopsOnMouseUp() {
        let (view, window) = makeView()
        defer { window.close() }
        let outside = CGPoint(x: 20, y: view.bounds.maxY + 1)
        mouse(view, .leftMouseDown, at: point(view, col: 2, row: 3))
        mouse(view, .leftMouseDragged, at: outside)
        let deadline = Date(timeIntervalSinceNow: 1)
        while view.withTerminal({ $0.displayBuffer.yDisp }) == 20, Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: deadline)
        }
        #expect(view.withTerminal { $0.displayBuffer.yDisp } < 20)
        mouse(view, .leftMouseUp, at: outside)
        #expect(!view.selectionAutoScrollActive)
        let before = view.withTerminal { $0.displayBuffer.yDisp }
        view.scrollingTimerElapsed()
        #expect(view.withTerminal { $0.displayBuffer.yDisp } == before)
    }

    @Test func scrollbackLimitsClamp() {
        let (view, window) = makeView()
        defer { window.close() }
        for up in [true, false] {
            view.scrollTo(row: up ? 0 : Int.max)
            let before = view.withTerminal { $0.displayBuffer.yDisp }
            mouse(view, .leftMouseDown, at: point(view, col: 2, row: 3))
            mouse(view, .leftMouseDragged, at: CGPoint(x: 20, y: up ? view.bounds.maxY + 1 : -1))
            view.scrollingTimerElapsed()
            #expect(view.withTerminal { $0.displayBuffer.yDisp } == before)
        }
    }

    @Test func wordAndShiftSelectionKeepTheirAnchors() {
        let (view, window) = makeView()
        defer { window.close() }
        mouse(view, .leftMouseDown, at: point(view, col: 12, row: 3), clicks: 2)
        mouse(view, .leftMouseDragged, at: point(view, col: 16, row: 3), clicks: 2)
        #expect(view.withTerminal { _ in view.selection.getSelectedText() } == "abc def")
        mouse(view, .leftMouseUp, at: point(view, col: 16, row: 3), clicks: 2)
        mouse(view, .leftMouseDown, at: point(view, col: 2, row: 3))
        mouse(view, .leftMouseDragged, at: point(view, col: 4, row: 3))
        mouse(view, .leftMouseUp, at: point(view, col: 4, row: 3))
        mouse(view, .leftMouseDown, at: point(view, col: 6, row: 3), flags: .shift)
        mouse(view, .leftMouseDragged, at: point(view, col: 8, row: 3), flags: .shift)
        #expect(view.withTerminal { _ in view.selection.getSelectedText() } == "234567")
    }

    @Test func invalidatedWordSelectionDoesNotRestart() {
        let (view, window) = makeView()
        defer { window.close() }
        mouse(view, .leftMouseDown, at: point(view, col: 12, row: 3), clicks: 2)
        view.withTerminal { _ in view.selection.selectNone() }
        mouse(view, .leftMouseDragged, at: point(view, col: 16, row: 3), clicks: 2)
        #expect(!view.withTerminal { _ in view.selection.active })
    }

    @Test func explicitShiftCaptureDoesNotStartLocalSelection() {
        let (view, window) = makeView()
        defer { window.close() }
        view.withTerminal { $0.feed(text: "\u{1b}[?1002h\u{1b}[>1s") }
        #expect(view.withTerminal { $0.mouseShiftCapture })
        mouse(view, .leftMouseDown, at: point(view, col: 2, row: 3), flags: .shift)
        mouse(view, .leftMouseDragged, at: CGPoint(x: 20, y: view.bounds.maxY + 1), flags: .shift)
        #expect(!view.withTerminal { _ in view.selection.active })
        #expect(!view.selectionAutoScrollActive)
    }
}
#endif
