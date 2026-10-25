import AppKit

/// The menu-bar fallback glyph: a display outline with a small sun inside,
/// matching the app icon's silhouette. Drawn in code so it renders
/// identically whether the executable runs bundled or via `swift run`
/// (an unbundled SwiftPM executable has no resource bundle to load from).
/// Template image: macOS tints it for menu-bar appearance and highlight.
@MainActor
func makeStatusGlyph() -> NSImage {
    let image = NSImage(size: NSSize(width: 17, height: 17), flipped: true) { _ in
        NSColor.black.set()

        // Display outline.
        let screen = NSBezierPath(
            roundedRect: NSRect(x: 1.5, y: 3, width: 14, height: 9),
            xRadius: 1.8, yRadius: 1.8)
        screen.lineWidth = 1.4
        screen.stroke()

        // Base line under the display.
        let base = NSBezierPath()
        base.move(to: NSPoint(x: 6.5, y: 14.5))
        base.line(to: NSPoint(x: 10.5, y: 14.5))
        base.lineWidth = 1.4
        base.lineCapStyle = .round
        base.stroke()

        // Sun disc, centered on the screen.
        NSBezierPath(ovalIn: NSRect(x: 6.7, y: 5.7, width: 3.6, height: 3.6)).fill()

        // Four cardinal rays (diagonals dropped at this size for clarity).
        let rays = NSBezierPath()
        rays.move(to: NSPoint(x: 8.5, y: 4.4)); rays.line(to: NSPoint(x: 8.5, y: 5.2))
        rays.move(to: NSPoint(x: 8.5, y: 9.8)); rays.line(to: NSPoint(x: 8.5, y: 10.6))
        rays.move(to: NSPoint(x: 5.4, y: 7.5)); rays.line(to: NSPoint(x: 6.2, y: 7.5))
        rays.move(to: NSPoint(x: 10.8, y: 7.5)); rays.line(to: NSPoint(x: 11.6, y: 7.5))
        rays.lineWidth = 1.1
        rays.lineCapStyle = .round
        rays.stroke()

        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Auto Brightness"
    return image
}

/// Shown in place of the usual glyph while the macOS brightness service is
/// stuck, so the menu bar itself says something is wrong.
@MainActor
func makeServiceStuckGlyph() -> NSImage {
    let description = "Auto Brightness: brightness service not responding"
    let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: description)
        ?? makeStatusGlyph()
    image.isTemplate = true
    return image
}
