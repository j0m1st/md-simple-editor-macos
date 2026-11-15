import AppKit

enum EditorMode: String { case raw, formatted }

/// Global editor preferences, shared by every open window.
enum Settings {
    static let changed = Notification.Name("MDEditSettingsChanged")

    static var fontSize: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: "fontSize"); return v > 0 ? v : 14 }
        set {
            UserDefaults.standard.set(Double(min(max(newValue, 9), 40)), forKey: "fontSize")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static var mode: EditorMode {
        get { EditorMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .formatted }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "mode")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}

extension NSAttributedString.Key {
    /// Character takes no space and is not drawn (Markdown syntax on an inactive line).
    static let mdHide = NSAttributedString.Key("md.hide")
    /// Character lays out as a tab (table column separator).
    static let mdTab = NSAttributedString.Key("md.tab")
    /// Character is drawn as this string's first character instead (list bullet).
    static let mdGlyph = NSAttributedString.Key("md.glyph")
    /// Block decoration drawn behind the text (`Block`).
    static let mdBlock = NSAttributedString.Key("md.block")
    /// Task checkbox `[ ]` / `[x]`; value is a Bool (checked).
    static let mdCheckbox = NSAttributedString.Key("md.checkbox")
}

final class Block: NSObject {
    enum Kind { case code, quote, rule, table }
    let kind: Kind
    var columns: [CGFloat] = []  // table: x where each column's text starts
    var width: CGFloat = 0       // table: total width
    init(_ kind: Kind) { self.kind = kind }
    static let quote = Block(.quote)
    static let rule = Block(.rule)
}

/// Formatted mode works like Obsidian's live preview: Markdown syntax is hidden, except on the
/// lines that hold the cursor or selection, where it is shown so it can be edited. The characters
/// are never changed, so the file on disk is exactly the Markdown that was typed.
final class MarkdownStyler: NSObject, NSTextStorageDelegate, NSTextViewDelegate, NSLayoutManagerDelegate {
    weak var textView: NSTextView?
    private var fences: [Fence] = []
    private var active = NSRange(location: 0, length: 0)
    private var refreshQueued = false
    private var processing = false

    private var formatted: Bool { Settings.mode == .formatted }

    // MARK: Attributes

    private var rawAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: Settings.fontSize, weight: .regular),
         .foregroundColor: NSColor.textColor]
    }

    private var bodySize: CGFloat { Settings.fontSize + 1 }

    private var bodyParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        p.paragraphSpacing = 3
        return p
    }

    private var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.textColor,
         .paragraphStyle: bodyParagraph]
    }

    private static let dim = NSColor.tertiaryLabelColor

    // MARK: Patterns (single-line; `.` never crosses a newline)

    private static func rx(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines])
    }
    private static let heading = rx(#"^[ \t]{0,3}(#{1,6})(?=[ \t]|$)[ \t]*"#)
    private static let bold = rx(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = rx(#"(?<![*_\w\\])([*_])(?![*_\s])(.+?)(?<![*_\s\\])\1(?![*_\w])"#)
    private static let strike = rx(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let code = rx(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let link = rx(#"(!?\[)([^\]\n]*)(\]\([^)\n]*\))"#)
    private static let quote = rx(#"^[ \t]{0,3}>[ \t]?"#)
    private static let list = rx(#"^[ \t]*([-*+]|\d{1,9}[.)])([ \t]+)(\[[ xX]\](?=[ \t]|$))?"#)
    private static let rule = rx(#"^[ \t]{0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let tableSeparator = rx(#"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)

    // MARK: Entry points

    /// Re-applies styling to the whole document (mode or font size changed, file loaded).
    func restyleAll(_ tv: NSTextView) {
        guard let ts = tv.textStorage else { return }
        let all = NSRange(location: 0, length: ts.length)
        ts.beginEditing()
        if formatted {
            fences = Self.fenceLines(ts.string as NSString)
            active = activeRange(tv)
            style(ts, all)
        } else {
            ts.setAttributes(rawAttributes, range: all)
        }
        ts.endEditing()
        tv.typingAttributes = formatted ? bodyAttributes : rawAttributes
        tv.setNeedsDisplay(tv.visibleRect)
    }

    /// While typing, restyles only the edited lines so large files stay fast.
    func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                     range: NSRange, changeInLength delta: Int) {
        guard formatted, mask.contains(.editedCharacters) else { return }
        processing = true
        defer { processing = false }
        let s = ts.string as NSString
        let newFences = Self.fenceLines(s)
        var r = s.paragraphRange(for: range)
        // Opening or closing a code fence changes how everything below it looks.
        let fenceChanged = newFences.count != fences.count
            || newFences.contains { NSLocationInRange($0.start, r) }
        fences = newFences
        active = expand(r, s)  // the edited lines are where the user is working
        if fenceChanged { r = NSRange(location: r.location, length: s.length - r.location) }
        style(ts, NSUnionRange(expand(r, s), active))
        if let tv = textView { tv.setNeedsDisplay(tv.visibleRect) }
        queueRefresh()  // edits away from the cursor (replace all, undo) settle on the real selection
    }

    func textViewDidChangeSelection(_ notification: Notification) { refreshActive() }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refreshActive()
        }
    }

    /// Reveals syntax on the lines under the selection and hides it on the lines just left.
    private func refreshActive() {
        guard formatted, let tv = textView, let ts = tv.textStorage else { return }
        if processing { queueRefresh(); return }
        let new = activeRange(tv)
        guard new != active else { return }
        let old = active
        active = new
        ts.beginEditing()
        restyle(ts, old)
        restyle(ts, new)
        ts.endEditing()
        // Table and code backgrounds extend past the glyphs TextKit invalidates, so repaint the
        // whole visible area to avoid leftover fragments of the previous rendering.
        tv.setNeedsDisplay(tv.visibleRect)
    }

    private func restyle(_ ts: NSTextStorage, _ range: NSRange) {
        let s = ts.string as NSString
        let loc = min(range.location, s.length)
        let r = s.paragraphRange(for: NSRange(location: loc, length: min(range.length, s.length - loc)))
        style(ts, expand(r, s))
    }

    private func activeRange(_ tv: NSTextView) -> NSRange {
        let s = tv.string as NSString
        var result: NSRange?
        for value in tv.selectedRanges {
            let r = value.rangeValue
            let loc = min(r.location, s.length)
            let p = s.paragraphRange(for: NSRange(location: loc, length: min(r.length, s.length - loc)))
            result = result.map { NSUnionRange($0, p) } ?? p
        }
        return expand(result ?? NSRange(location: 0, length: 0), s)
    }

    /// Grows a line range to cover whole code blocks and tables, which are styled as a unit.
    private func expand(_ range: NSRange, _ s: NSString) -> NSRange {
        var r = range
        for b in Self.blocks(fences, length: s.length)
        where NSIntersectionRange(b.range, r).length > 0 || NSLocationInRange(r.location, b.range) {
            r = NSUnionRange(r, b.range)
        }
        func hasPipe(_ line: NSRange) -> Bool {
            line.length > 0 && s.range(of: "|", options: .literal, range: line).location != NSNotFound
        }
        var first = s.lineRange(for: NSRange(location: r.location, length: 0))
        if hasPipe(first) {
            while first.location > 0 {
                let prev = s.lineRange(for: NSRange(location: first.location - 1, length: 0))
                guard hasPipe(prev) else { break }
                first = prev
            }
            r = NSUnionRange(r, first)
        }
        var last = s.lineRange(for: NSRange(location: max(NSMaxRange(r) - 1, r.location), length: 0))
        if hasPipe(last) {
            while NSMaxRange(last) < s.length {
                let next = s.lineRange(for: NSRange(location: NSMaxRange(last), length: 0))
                guard hasPipe(next) else { break }
                last = next
            }
            r = NSUnionRange(r, last)
        }
        return r
    }

    // MARK: Styling

    private func style(_ ts: NSTextStorage, _ range: NSRange) {
        guard range.length > 0 else { return }
        let text = ts.string
        let s = text as NSString
        let active = self.active
        ts.setAttributes(bodyAttributes, range: range)

        func isActive(_ r: NSRange) -> Bool { NSIntersectionRange(r, active).length > 0 }
        func dim(_ r: NSRange) { ts.addAttribute(.foregroundColor, value: Self.dim, range: r) }
        func hide(_ r: NSRange) { if r.length > 0 { ts.addAttribute(.mdHide, value: true, range: r) } }
        func syntax(_ r: NSRange, _ act: Bool) { act ? dim(r) : hide(r) }

        // Code (fenced blocks and inline spans) is literal: nothing inside it is styled.
        let codeBlocks = Self.blocks(fences, length: s.length).filter { NSIntersectionRange($0.range, range).length > 0 }
        let literal = NSMutableIndexSet()
        for b in codeBlocks { literal.add(in: b.range) }
        let fenced = literal.copy() as! NSIndexSet
        var inlineCode: [NSTextCheckingResult] = []
        Self.code.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let m = m, !literal.intersects(in: m.range) else { return }
            inlineCode.append(m)
        }
        for m in inlineCode { literal.add(in: m.range) }

        func each(_ re: NSRegularExpression, _ body: (NSTextCheckingResult, Bool) -> Void) {
            re.enumerateMatches(in: text, range: range) { m, _, _ in
                guard let m = m, !literal.intersects(in: m.range) else { return }
                body(m, isActive(s.lineRange(for: m.range)))
            }
        }

        each(Self.heading) { m, act in
            let level = m.range(at: 1).length
            let scale: [CGFloat] = [1.75, 1.45, 1.25, 1.1, 1.0, 1.0]
            let size = bodySize * scale[level - 1]
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.1
            p.paragraphSpacingBefore = size * 0.45
            p.paragraphSpacing = size * 0.2
            ts.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: .bold), .paragraphStyle: p],
                             range: s.lineRange(for: m.range))
            syntax(m.range, act)
        }
        each(Self.quote) { m, act in
            let line = s.lineRange(for: m.range)
            let p = bodyParagraph.mutableCopy() as! NSMutableParagraphStyle
            p.firstLineHeadIndent = 16
            p.headIndent = 16
            ts.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p,
                              .mdBlock: Block.quote], range: line)
            syntax(m.range, act)
        }
        each(Self.list) { m, act in
            let marker = m.range(at: 1), gap = m.range(at: 2), box = m.range(at: 3)
            let ordered = CharacterSet.decimalDigits.contains(Unicode.Scalar(s.character(at: marker.location)) ?? " ")
            if box.location != NSNotFound {
                let checked = s.substring(with: box).lowercased() == "[x]"
                if act {
                    ts.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: NSUnionRange(marker, box))
                } else {
                    hide(NSUnionRange(marker, gap))
                    ts.addAttributes([.mdCheckbox: checked, .foregroundColor: NSColor.clear], range: box)
                    if checked {
                        let line = self.contentRange(s, s.lineRange(for: m.range))
                        let rest = NSRange(location: NSMaxRange(box), length: NSMaxRange(line) - NSMaxRange(box))
                        ts.addAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                                          .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: rest)
                    }
                }
            } else if ordered {
                ts.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: marker)
            } else {
                ts.addAttribute(.foregroundColor, value: act ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                                range: marker)
                if !act { ts.addAttribute(.mdGlyph, value: "•", range: marker) }
            }
        }
        each(Self.rule) { m, act in
            if act { dim(m.range) } else {
                hide(m.range)
                ts.addAttribute(.mdBlock, value: Block.rule, range: s.lineRange(for: m.range))
            }
        }
        each(Self.bold) { m, act in
            addTrait(ts, m.range, .boldFontMask)
            let n = m.range(at: 1).length
            syntax(NSRange(location: m.range.location, length: n), act)
            syntax(NSRange(location: NSMaxRange(m.range) - n, length: n), act)
        }
        each(Self.italic) { m, act in
            addTrait(ts, m.range, .italicFontMask)
            syntax(NSRange(location: m.range.location, length: 1), act)
            syntax(NSRange(location: NSMaxRange(m.range) - 1, length: 1), act)
        }
        each(Self.strike) { m, act in
            ts.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                              .foregroundColor: NSColor.secondaryLabelColor], range: m.range(at: 1))
            syntax(NSRange(location: m.range.location, length: 2), act)
            syntax(NSRange(location: NSMaxRange(m.range) - 2, length: 2), act)
        }
        each(Self.link) { m, act in
            ts.addAttributes([.foregroundColor: NSColor.linkColor,
                              .underlineStyle: NSUnderlineStyle.single.rawValue], range: m.range(at: 2))
            syntax(m.range(at: 1), act)
            syntax(m.range(at: 3), act)
        }
        for m in inlineCode {
            let act = isActive(s.lineRange(for: m.range))
            makeMono(ts, m.range)
            ts.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.15), range: m.range(at: 2))
            let n = m.range(at: 1).length
            syntax(NSRange(location: m.range.location, length: n), act)
            syntax(NSRange(location: NSMaxRange(m.range) - n, length: n), act)
        }

        for b in codeBlocks {
            let r = NSIntersectionRange(b.range, range)
            let act = isActive(b.range)
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.1
            p.firstLineHeadIndent = 12
            p.headIndent = 12
            p.tailIndent = -12
            ts.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: bodySize * 0.88, weight: .regular),
                              .foregroundColor: NSColor.textColor, .paragraphStyle: p,
                              .mdBlock: Block(.code)], range: r)
            for line in b.fenceLines where NSIntersectionRange(line, range).length > 0 {
                if act { dim(line) } else {
                    hide(contentRange(s, line))
                    ts.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 6, weight: .regular), range: line)
                }
            }
        }

        styleTables(ts, s, range, fenced, isActive)
    }

    // MARK: Tables

    private func styleTables(_ ts: NSTextStorage, _ s: NSString, _ range: NSRange,
                             _ literal: NSIndexSet, _ isActive: (NSRange) -> Bool) {
        var lines: [NSRange] = []
        s.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            lines.append(enclosing)
        }
        func hasPipe(_ l: NSRange) -> Bool {
            s.range(of: "|", options: .literal, range: l).location != NSNotFound
        }
        var i = 0
        while i + 1 < lines.count {
            let header = lines[i], sep = contentRange(s, lines[i + 1])
            guard hasPipe(header), !literal.intersects(in: header), hasPipe(sep),
                  Self.tableSeparator.firstMatch(in: s as String, range: sep) != nil else { i += 1; continue }
            var j = i + 2
            while j < lines.count, hasPipe(lines[j]), !literal.intersects(in: lines[j]) { j += 1 }
            styleTable(ts, s, Array(lines[i..<j]), isActive)
            i = j
        }
    }

    private func styleTable(_ ts: NSTextStorage, _ s: NSString, _ lines: [NSRange], _ isActive: (NSRange) -> Bool) {
        let all = NSUnionRange(lines.first!, lines.last!)
        if isActive(all) {
            // Editing: show the raw table in one monospaced font so the pipes line up.
            ts.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: bodySize * 0.88, weight: .regular),
                            range: all)
            for l in lines { dimPipes(ts, s, l) }
            ts.addAttribute(.foregroundColor, value: Self.dim, range: lines[1])
            return
        }

        let pad: CGFloat = 10
        var widths: [CGFloat] = []
        var rows: [NSRange] = []
        for (index, line) in lines.enumerated() where index != 1 {
            let c = contentRange(s, line)
            if index == 0 { addTrait(ts, c, .boldFontMask) }
            let cells = splitRow(ts, s, c)
            for (k, cell) in cells.enumerated() {
                let w = cell.length > 0 ? ceil(ts.attributedSubstring(from: cell).size().width) : 0
                if k < widths.count { widths[k] = max(widths[k], w) } else { widths.append(w) }
            }
            rows.append(line)
        }
        guard !widths.isEmpty else { return }

        var starts: [CGFloat] = [pad]
        for k in 1..<max(widths.count, 1) { starts.append(starts[k - 1] + widths[k - 1] + 2 * pad) }
        let block = Block(.table)
        block.columns = starts
        block.width = starts.last! + widths.last! + pad

        let row = NSMutableParagraphStyle()
        row.firstLineHeadIndent = pad
        row.headIndent = pad
        row.tabStops = starts.dropFirst().map { NSTextTab(textAlignment: .left, location: $0) }
        row.defaultTabInterval = 40
        row.lineHeightMultiple = 1.1
        row.paragraphSpacingBefore = 5
        row.paragraphSpacing = 5
        for r in rows { ts.addAttribute(.paragraphStyle, value: row, range: r) }

        // The |---|---| line collapses to a hairline under the header.
        let sepStyle = NSMutableParagraphStyle()
        sepStyle.minimumLineHeight = 1
        sepStyle.maximumLineHeight = 1
        ts.addAttributes([.paragraphStyle: sepStyle, .font: NSFont.systemFont(ofSize: 1)], range: lines[1])
        ts.addAttribute(.mdHide, value: true, range: contentRange(s, lines[1]))
        ts.addAttribute(.mdBlock, value: block, range: all)
    }

    /// Hides a row's outer pipes and cell padding, turns inner pipes into tabs, returns the cells.
    private func splitRow(_ ts: NSTextStorage, _ s: NSString, _ c: NSRange) -> [NSRange] {
        var pipes: [Int] = []
        for i in c.location..<NSMaxRange(c) where s.character(at: i) == 124 { pipes.append(i) }
        func isSpace(_ i: Int) -> Bool { let ch = s.character(at: i); return ch == 32 || ch == 9 }
        var first = c.location, last = NSMaxRange(c)
        while first < last, isSpace(first) { first += 1 }
        while last > first, isSpace(last - 1) { last -= 1 }
        let lead = pipes.first == first
        let trail = pipes.count > (lead ? 1 : 0) && pipes.last == last - 1
        var inner = pipes
        if lead { inner.removeFirst() }
        if trail { inner.removeLast() }

        func hide(_ a: Int, _ b: Int) { if b > a { ts.addAttribute(.mdHide, value: true, range: NSRange(location: a, length: b - a)) } }
        var cells: [NSRange] = []
        var a = lead ? first + 1 : c.location
        hide(c.location, a)
        for edge in inner + [trail ? last - 1 : NSMaxRange(c)] {
            var ta = a, tb = edge
            while ta < tb, isSpace(ta) { ta += 1 }
            while tb > ta, isSpace(tb - 1) { tb -= 1 }
            hide(a, ta)
            hide(tb, edge)
            cells.append(NSRange(location: ta, length: tb - ta))
            a = edge + 1
        }
        for p in inner { ts.addAttribute(.mdTab, value: true, range: NSRange(location: p, length: 1)) }
        if trail { hide(last - 1, NSMaxRange(c)) }
        return cells
    }

    private func dimPipes(_ ts: NSTextStorage, _ s: NSString, _ line: NSRange) {
        for i in line.location..<NSMaxRange(line) where s.character(at: i) == 124 {
            ts.addAttribute(.foregroundColor, value: Self.dim, range: NSRange(location: i, length: 1))
        }
    }

    // MARK: Helpers

    private func contentRange(_ s: NSString, _ line: NSRange) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location, [10, 13].contains(s.character(at: end - 1)) { end -= 1 }
        return NSRange(location: line.location, length: end - line.location)
    }

    private func makeMono(_ ts: NSTextStorage, _ r: NSRange) {
        ts.enumerateAttribute(.font, in: r) { value, sub, _ in
            let size = (value as? NSFont)?.pointSize ?? bodySize
            ts.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size * 0.88, weight: .regular), range: sub)
        }
    }

    private func addTrait(_ ts: NSTextStorage, _ r: NSRange, _ trait: NSFontTraitMask) {
        let fm = NSFontManager.shared
        ts.enumerateAttribute(.font, in: r) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            let converted = fm.convert(font, toHaveTrait: trait)
            ts.addAttribute(.font, value: converted, range: sub)
            if trait == .italicFontMask, !fm.traits(of: converted).contains(.italicFontMask) {
                ts.addAttribute(.obliqueness, value: 0.18, range: sub)  // font has no italic face
            }
        }
    }

    // MARK: Glyph generation (hiding syntax, bullets, table tabs)

    func layoutManager(_ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font: NSFont,
                       forGlyphRange range: NSRange) -> Int {
        guard let ts = lm.textStorage, range.length > 0 else { return 0 }
        var newGlyphs: [CGGlyph]?
        var newProps: [NSLayoutManager.GlyphProperty]?
        func prepare() {
            if newGlyphs == nil {
                newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: range.length))
                newProps = Array(UnsafeBufferPointer(start: props, count: range.length))
            }
        }
        var run = NSRange(location: NSNotFound, length: 0)
        var attrs: [NSAttributedString.Key: Any] = [:]
        for i in 0..<range.length {
            let ci = charIndexes[i]
            guard ci < ts.length else { continue }
            if !NSLocationInRange(ci, run) { attrs = ts.attributes(at: ci, effectiveRange: &run) }
            // Hidden characters become zero-width control glyphs rather than `.null` ones:
            // null glyphs at the start of a line get laid out on the previous line.
            if attrs[.mdHide] != nil || attrs[.mdTab] != nil {
                prepare(); newProps![i] = .controlCharacter
            } else if let sub = attrs[.mdGlyph] as? String, var u = sub.utf16.first {
                var g = CGGlyph(0)
                if CTFontGetGlyphsForCharacters(font, &u, &g, 1) { prepare(); newGlyphs![i] = g }
            }
        }
        guard let g = newGlyphs, let p = newProps else { return 0 }
        lm.setGlyphs(g, properties: p, characterIndexes: charIndexes, font: font, forGlyphRange: range)
        return range.length
    }

    func layoutManager(_ lm: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt ci: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let ts = lm.textStorage, ci < ts.length else { return action }
        let attrs = ts.attributes(at: ci, effectiveRange: nil)
        if attrs[.mdHide] != nil { return .zeroAdvancement }
        if attrs[.mdTab] != nil { return .horizontalTab }
        return action
    }

    // MARK: Fenced code blocks

    struct Fence { let start: Int; let lineEnd: Int; let kind: String }

    /// Lines that start with ``` or ~~~ (up to 3 leading spaces), in document order.
    static func fenceLines(_ s: NSString) -> [Fence] {
        var found: [Fence] = []
        for kind in ["```", "~~~"] {
            var from = 0
            while from < s.length {
                let hit = s.range(of: kind, options: .literal, range: NSRange(location: from, length: s.length - from))
                if hit.location == NSNotFound { break }
                let line = s.lineRange(for: NSRange(location: hit.location, length: 0))
                let indent = hit.location - line.location
                if indent <= 3, (line.location..<hit.location).allSatisfy({ s.character(at: $0) == 32 }) {
                    found.append(Fence(start: line.location, lineEnd: NSMaxRange(line), kind: kind))
                }
                from = NSMaxRange(line)  // one fence per line at most
            }
        }
        return found.sorted { $0.start < $1.start }
    }

    /// Pairs fence lines into blocks; an unclosed fence runs to the end of the document.
    static func blocks(_ fences: [Fence], length: Int) -> [(range: NSRange, fenceLines: [NSRange])] {
        var result: [(NSRange, [NSRange])] = []
        var open: Fence?
        for f in fences {
            if let o = open {
                guard f.kind == o.kind else { continue }
                result.append((NSRange(location: o.start, length: f.lineEnd - o.start),
                               [NSRange(location: o.start, length: o.lineEnd - o.start),
                                NSRange(location: f.start, length: f.lineEnd - f.start)]))
                open = nil
            } else {
                open = f
            }
        }
        if let o = open {
            result.append((NSRange(location: o.start, length: length - o.start),
                           [NSRange(location: o.start, length: o.lineEnd - o.start)]))
        }
        return result
    }
}
