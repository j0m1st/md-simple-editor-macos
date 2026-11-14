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

/// Styles the text storage in place. The characters are never touched, so the file
/// on disk is always exactly the Markdown that was typed; only the display changes.
final class MarkdownStyler: NSObject, NSTextStorageDelegate {
    private var fenceCount = -1

    // MARK: Attributes

    private var rawAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: Settings.fontSize, weight: .regular),
         .foregroundColor: NSColor.textColor]
    }

    private var bodyAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        p.paragraphSpacing = 2
        return [.font: NSFont.systemFont(ofSize: Settings.fontSize + 1),
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: p]
    }

    private static let dim = NSColor.tertiaryLabelColor
    private static let codeBackground = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)

    // MARK: Patterns (all single-line; `.` never crosses a newline)

    private static func rx(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines])
    }
    private static let heading = rx(#"^[ \t]{0,3}(#{1,6})(?:[ \t]+.*)?$"#)
    private static let bold = rx(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = rx(#"(?<![*_\w\\])([*_])(?![*_\s])(.+?)(?<![*_\s\\])\1(?![*_\w])"#)
    private static let strike = rx(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let code = rx(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let link = rx(#"!?\[([^\]\n]*)\]\(([^)\n]*)\)"#)
    private static let quote = rx(#"^[ \t]{0,3}>.*$"#)
    private static let list = rx(#"^[ \t]*(?:[-*+]|\d{1,9}[.)])(?:[ \t]+\[[ xX]\])?(?=[ \t])"#)
    private static let rule = rx(#"^[ \t]{0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)

    // MARK: Entry points

    /// Re-applies styling to the whole document (mode or font size changed, file loaded).
    func restyleAll(_ tv: NSTextView) {
        guard let ts = tv.textStorage else { return }
        let all = NSRange(location: 0, length: ts.length)
        ts.beginEditing()
        if Settings.mode == .raw {
            ts.setAttributes(rawAttributes, range: all)
        } else {
            let fences = Self.fenceLines(ts.string as NSString)
            fenceCount = fences.count
            style(ts, all, fences)
        }
        ts.endEditing()
        tv.typingAttributes = Settings.mode == .raw ? rawAttributes : bodyAttributes
    }

    /// Restyles only the edited lines while typing, so large files stay fast.
    func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                     range: NSRange, changeInLength delta: Int) {
        guard Settings.mode == .formatted, mask.contains(.editedCharacters) else { return }
        let s = ts.string as NSString
        var r = s.paragraphRange(for: range)
        let fences = Self.fenceLines(s)
        // Opening or closing a code fence changes how everything below it looks.
        if fences.count != fenceCount || fences.contains(where: { NSLocationInRange($0.start, r) }) {
            r = NSRange(location: r.location, length: s.length - r.location)
        }
        fenceCount = fences.count
        style(ts, r, fences)
    }

    // MARK: Styling

    private func style(_ ts: NSTextStorage, _ range: NSRange, _ fences: [Fence]) {
        guard range.length > 0 else { return }
        let text = ts.string
        ts.setAttributes(bodyAttributes, range: range)

        func each(_ re: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            re.enumerateMatches(in: text, range: range) { m, _, _ in if let m = m { body(m) } }
        }
        func dim(_ r: NSRange) { ts.addAttribute(.foregroundColor, value: Self.dim, range: r) }
        func markers(_ m: NSTextCheckingResult, _ len: Int) {
            dim(NSRange(location: m.range.location, length: len))
            dim(NSRange(location: NSMaxRange(m.range) - len, length: len))
        }

        each(Self.heading) { m in
            let level = m.range(at: 1).length
            let scale: [CGFloat] = [1.7, 1.45, 1.25, 1.1, 1.0, 1.0]
            let size = (Settings.fontSize + 1) * scale[level - 1]
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.1
            p.paragraphSpacingBefore = size * 0.4
            p.paragraphSpacing = size * 0.15
            ts.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: .bold), .paragraphStyle: p],
                             range: m.range)
            dim(m.range(at: 1))
        }
        each(Self.quote) { m in
            ts.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
            addTrait(ts, m.range, .italicFontMask)
        }
        each(Self.list) { m in
            ts.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: m.range)
        }
        each(Self.bold) { m in
            addTrait(ts, m.range, .boldFontMask)
            markers(m, m.range(at: 1).length)
        }
        each(Self.italic) { m in
            addTrait(ts, m.range, .italicFontMask)
            markers(m, 1)
        }
        each(Self.strike) { m in
            ts.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                              .foregroundColor: NSColor.secondaryLabelColor], range: m.range(at: 1))
            markers(m, 2)
        }
        each(Self.link) { m in
            dim(m.range)
            ts.addAttributes([.foregroundColor: NSColor.linkColor,
                              .underlineStyle: NSUnderlineStyle.single.rawValue], range: m.range(at: 1))
        }
        each(Self.rule) { m in dim(m.range) }
        each(Self.code) { m in
            makeCode(ts, m.range)
            markers(m, m.range(at: 1).length)
        }

        for block in Self.blocks(fences, length: (text as NSString).length) {
            let r = NSIntersectionRange(block.range, range)
            guard r.length > 0 else { continue }
            makeCode(ts, r)
            for line in block.fenceLines {
                let l = NSIntersectionRange(line, range)
                if l.length > 0 { dim(l) }
            }
        }
    }

    private func makeCode(_ ts: NSTextStorage, _ r: NSRange) {
        ts.enumerateAttribute(.font, in: r) { value, sub, _ in
            let size = (value as? NSFont)?.pointSize ?? Settings.fontSize
            ts.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular),
                            range: sub)
        }
        ts.removeAttribute(.obliqueness, range: r)
        ts.removeAttribute(.strikethroughStyle, range: r)
        ts.removeAttribute(.underlineStyle, range: r)
        ts.addAttributes([.foregroundColor: NSColor.textColor, .backgroundColor: Self.codeBackground], range: r)
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

    // MARK: Fenced code blocks

    struct Fence { let start: Int; let lineEnd: Int; let kind: String }

    /// Lines that start with ``` or ~~~ (up to 3 leading spaces), in document order.
    static func fenceLines(_ s: NSString) -> [Fence] {
        var found: [Fence] = []
        for kind in ["```", "~~~"] {
            var from = 0
            while from < s.length {
                let hit = s.range(of: kind, range: NSRange(location: from, length: s.length - from))
                if hit.location == NSNotFound { break }
                let line = s.lineRange(for: NSRange(location: hit.location, length: 0))
                let prefix = s.substring(with: NSRange(location: line.location, length: hit.location - line.location))
                if prefix.count <= 3, prefix.allSatisfy({ $0 == " " }) {
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
