import AppKit
import SwiftUI
import CreatorMicroStudioKit

/// The menu-bar icon.
///
/// Menu-bar images are drawn as templates (flattened to monochrome) unless the
/// NSImage says otherwise, so a coloured status needs `isTemplate = false` and
/// an explicitly drawn dot. Neutral states stay templated so they follow the
/// menu bar's own light/dark appearance.
enum MenuBarIcon {

    enum State: Hashable {
        case off
        case permissionDenied
        case deviceMissing
        case idle            // running, no agents
        case allIdle
        case working
        case blocked

        /// Derived from the bridge, in the order that matters: problems first,
        /// then attention, then activity.
        @MainActor
        static func from(_ bridge: BridgeController) -> State {
            guard bridge.isRunning else { return .off }
            if bridge.permissionDenied { return .permissionDenied }
            if !bridge.deviceConnected { return .deviceMissing }
            guard let state = bridge.aggregateState else { return .idle }
            switch state {
            case "blocked": return .blocked
            case "working": return .working
            default: return .allIdle
            }
        }

        /// Active states fill the keys; off and idle draw them as outlines.
        var keysFilled: Bool {
            switch self {
            case .off, .idle, .permissionDenied, .deviceMissing: return false
            case .allIdle, .working, .blocked: return true
            }
        }

        /// nil keeps the icon templated, so it matches the menu bar.
        var dot: NSColor? {
            switch self {
            case .off, .idle: return nil
            case .permissionDenied: return .systemRed
            case .deviceMissing: return .systemGray
            case .allIdle: return NSColor(srgbRed: 0, green: 0.78, blue: 0.33, alpha: 1)
            case .working: return NSColor(srgbRed: 1, green: 0.63, blue: 0, alpha: 1)
            case .blocked: return NSColor(srgbRed: 1, green: 0.18, blue: 0.18, alpha: 1)
            }
        }

        var help: String {
            switch self {
            case .off: return "\(AppIdentity.displayName) is off"
            case .permissionDenied: return "Input Monitoring permission is needed"
            case .deviceMissing: return "Pad not found"
            case .idle: return "Running — no agents"
            case .allIdle: return "All agents idle"
            case .working: return "An agent is working"
            case .blocked: return "An agent needs you"
            }
        }
    }

    private enum Cell { case key, dial, joystick, caseMark }

    /// The Creator Micro 2 surface from above, as in the app icon artwork
    /// (`scripts/genicon.swift`): dial and joystick flank the top keys, and the
    /// bottom-left case mark is not a key.
    private static let surface: [[Cell]] = [
        [.dial, .key, .key, .joystick],
        [.key, .key, .key, .key],
        [.key, .key, .key, .key],
        [.caseMark, .key, .key, .key],
    ]

    /// One image per state: the drawing handler re-renders on appearance
    /// changes by itself, so there is no reason to build a new NSImage (and
    /// make the status item relayout) every time the label is asked.
    @MainActor private static var cache: [State: NSImage] = [:]

    @MainActor
    static func image(for state: State) -> NSImage {
        if let cached = cache[state] { return cached }
        let image = makeImage(for: state)
        cache[state] = image
        return image
    }

    private static func makeImage(for state: State) -> NSImage {
        let canvas = NSSize(width: 18, height: 18)
        let image = NSImage(size: canvas, flipped: true) { _ in
            drawPad(in: NSRect(x: 1, y: 1, width: 16, height: 16), state: state)
            if let dot = state.dot { drawDot(dot, canvas: canvas) }
            return true
        }
        // Templated images follow the menu bar's appearance; a coloured status
        // dot needs a non-template image, so draw the glyph in the label colour.
        image.isTemplate = state.dot == nil
        image.accessibilityDescription = state.help
        return image
    }

    private static func drawPad(in pad: NSRect, state: State) {
        let ink = NSColor.labelColor
        ink.setStroke()
        ink.setFill()

        let body = NSBezierPath(roundedRect: pad.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        body.lineWidth = 1
        body.stroke()

        let inset: CGFloat = 2.25
        let gap: CGFloat = 0.75
        let cell = (pad.width - inset * 2 - gap * 3) / 4

        for (row, cells) in surface.enumerated() {
            for (column, kind) in cells.enumerated() {
                let frame = NSRect(
                    x: pad.minX + inset + CGFloat(column) * (cell + gap),
                    y: pad.minY + inset + CGFloat(row) * (cell + gap),
                    width: cell, height: cell
                )
                switch kind {
                case .key:
                    let key = NSBezierPath(roundedRect: frame, xRadius: 0.7, yRadius: 0.7)
                    if state.keysFilled {
                        key.fill()
                    } else {
                        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.3, dy: 0.3), xRadius: 0.6, yRadius: 0.6)
                        outline.lineWidth = 0.6
                        outline.stroke()
                    }
                case .dial, .joystick:
                    let knob = NSBezierPath(ovalIn: frame.insetBy(dx: 0.3, dy: 0.3))
                    knob.lineWidth = 0.6
                    knob.stroke()
                case .caseMark:
                    NSBezierPath(ovalIn: frame.insetBy(dx: cell * 0.3, dy: cell * 0.3)).fill()
                }
            }
        }
    }

    private static func drawDot(_ color: NSColor, canvas: NSSize) {
        let diameter: CGFloat = 6
        let dotRect = NSRect(x: canvas.width - diameter, y: canvas.height - diameter, width: diameter, height: diameter)
        // Knock out a ring so the dot reads against the keys beneath it.
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: dotRect.insetBy(dx: -1, dy: -1)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }
}
