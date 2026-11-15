import AppKit

/// Draws the block decorations the styler marks with `.mdBlock` and `.mdCheckbox`.
final class MarkdownLayoutManager: NSLayoutManager {
    private static let codeFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.045)
    }
    private static let headerFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.035)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let ts = textStorage, let tc = textContainers.first {
            let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            var drawn = Set<ObjectIdentifier>()
            ts.enumerateAttribute(.mdBlock, in: chars) { value, r, _ in
                guard let block = value as? Block else { return }
                switch block.kind {
                case .quote, .rule:
                    for rect in fragments(r) { drawLine(block, rect.offsetBy(dx: origin.x, dy: origin.y), tc) }
                case .code, .table:
                    // Always draw the whole block, even when only part of it is being redrawn.
                    guard drawn.insert(ObjectIdentifier(block)).inserted else { return }
                    var full = NSRange()
                    _ = ts.attribute(.mdBlock, at: r.location, longestEffectiveRange: &full,
                                     in: NSRange(location: 0, length: ts.length))
                    let rects = fragments(full).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
                    if block.kind == .code { drawCode(rects, tc) } else { drawTable(block, rects, tc) }
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let ts = textStorage, let tc = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        ts.enumerateAttribute(.mdCheckbox, in: chars) { value, r, _ in
            guard let checked = value as? Bool else { return }
            let font = ts.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
            let size = round((font?.pointSize ?? 14) * 0.95)
            let gr = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            let line = lineFragmentUsedRect(forGlyphAt: gr.location, effectiveRange: nil)
            let glyphs = boundingRect(forGlyphRange: gr, in: tc)
            let box = NSRect(x: origin.x + glyphs.midX - size / 2,
                             y: origin.y + line.minY + (line.height - size) / 2, width: size, height: size)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
            if checked {
                NSColor.controlAccentColor.setFill()
                path.fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: box.minX + size * 0.24, y: box.minY + size * 0.52))
                tick.line(to: NSPoint(x: box.minX + size * 0.43, y: box.minY + size * 0.70))
                tick.line(to: NSPoint(x: box.minX + size * 0.77, y: box.minY + size * 0.30))
                tick.lineWidth = max(1.5, size * 0.12)
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                NSColor.white.setStroke()
                tick.stroke()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                path.lineWidth = 1.2
                path.stroke()
            }
        }
    }

    private func fragments(_ chars: NSRange) -> [NSRect] {
        var rects: [NSRect] = []
        let gr = glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
        enumerateLineFragments(forGlyphRange: gr) { rect, _, _, _, _ in rects.append(rect) }
        return rects
    }

    private func drawLine(_ block: Block, _ rect: NSRect, _ tc: NSTextContainer) {
        let pad = tc.lineFragmentPadding
        if block.kind == .quote {
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + pad, y: rect.minY, width: 3, height: rect.height),
                         xRadius: 1.5, yRadius: 1.5).fill()
        } else {
            NSColor.separatorColor.setFill()
            NSRect(x: rect.minX + pad, y: floor(rect.midY), width: tc.size.width - 2 * pad, height: 1).fill()
        }
    }

    private func drawCode(_ rects: [NSRect], _ tc: NSTextContainer) {
        guard let first = rects.first, let last = rects.last else { return }
        let pad = tc.lineFragmentPadding
        let box = NSRect(x: first.minX + pad, y: first.minY,
                         width: tc.size.width - 2 * pad, height: last.maxY - first.minY)
        Self.codeFill.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
    }

    private func drawTable(_ block: Block, _ rects: [NSRect], _ tc: NSTextContainer) {
        guard let first = rects.first, let last = rects.last, let firstColumn = block.columns.first else { return }
        let pad = tc.lineFragmentPadding
        let box = NSRect(x: first.minX + pad, y: first.minY,
                         width: min(block.width, tc.size.width - 2 * pad), height: last.maxY - first.minY)
        let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        Self.headerFill.setFill()
        NSRect(x: box.minX, y: box.minY, width: box.width, height: first.height).fill()
        NSColor.separatorColor.setFill()
        for (i, r) in rects.enumerated() where i < rects.count - 1 && r.height >= 4 {
            NSRect(x: box.minX, y: r.maxY - 0.5, width: box.width, height: 1).fill()
        }
        for x in block.columns.dropFirst() {
            NSRect(x: box.minX + x - firstColumn - 0.5, y: box.minY, width: 1, height: box.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}

/// Plain-text editor view; clicking a rendered task checkbox toggles it.
final class MarkdownTextView: NSTextView {
    var styler: MarkdownStyler?  // strong: lives exactly as long as the view

    override func mouseDown(with event: NSEvent) {
        if toggleCheckbox(at: convert(event.locationInWindow, from: nil)) { return }
        super.mouseDown(with: event)
    }

    private func toggleCheckbox(at point: NSPoint) -> Bool {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return false }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: p, in: tc)
        let ci = lm.characterIndexForGlyph(at: glyph)
        guard ci < ts.length else { return false }
        var r = NSRange()
        guard let checked = ts.attribute(.mdCheckbox, at: ci, effectiveRange: &r) as? Bool else { return false }
        let hit = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
        guard hit.insetBy(dx: -3, dy: -3).contains(p) else { return false }
        let mark = NSRange(location: r.location + 1, length: 1)
        let replacement = checked ? " " : "x"
        if shouldChangeText(in: mark, replacementString: replacement) {
            ts.replaceCharacters(in: mark, with: replacement)
            didChangeText()
        }
        return true
    }
}
