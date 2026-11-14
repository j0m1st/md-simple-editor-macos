import AppKit
import UniformTypeIdentifiers

let markdownType = UTType("net.daringfireball.markdown") ?? .plainText

/// Makes this app the default handler for Markdown files.
func makeDefaultMarkdownApp(_ completion: @escaping (Error?) -> Void) {
    NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: markdownType) { error in
        completion(error)
    }
}

func isDefaultMarkdownApp() -> Bool {
    NSWorkspace.shared.urlForApplication(toOpen: markdownType)?.standardizedFileURL
        == Bundle.main.bundleURL.standardizedFileURL
}

// MARK: - Document

@objc(Document)
final class Document: NSDocument {
    private var text = ""
    private weak var textView: NSTextView?
    private let styler = MarkdownStyler()

    override class var autosavesInPlace: Bool { true }

    @objc private func settingsChanged(_ note: Notification) {
        if let tv = textView { styler.restyleAll(tv) }
    }

    override func makeWindowControllers() {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.layoutManager?.allowsNonContiguousLayout = true  // fast with large files
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFontPanel = false
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 18, height: 16)
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        // Markdown is plain text: never let the system rewrite what is typed.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.textStorage?.delegate = styler
        tv.string = text
        styler.restyleAll(tv)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        textView = tv
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: Settings.changed, object: nil)

        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: min(760, visible.width - 40),
                                height: min(820, visible.height - 80)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.initialFirstResponder = tv
        window.center()
        addWindowController(NSWindowController(window: window))
    }

    override func data(ofType typeName: String) throws -> Data {
        if let tv = textView { text = tv.string }
        return Data(text.utf8)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        var decoded: String? = String(data: data, encoding: .utf8)
        if decoded == nil {
            var converted: NSString?
            let enc = NSString.stringEncoding(for: data, encodingOptions: nil,
                                              convertedString: &converted, usedLossyConversion: nil)
            if enc != 0 { decoded = converted as String? }
        }
        guard let string = decoded else {
            throw CocoaError(.fileReadUnknownStringEncoding)
        }
        text = string
        if let tv = textView {  // revert of an already-open document
            tv.string = string
            styler.restyleAll(tv)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func makeDefault(_ sender: Any?) {
        makeDefaultMarkdownApp { error in
            DispatchQueue.main.async {
                let alert = NSAlert()
                if let error = error {
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn’t set the default app"
                    alert.informativeText = "macOS asks you to confirm this change. Choose “Use MDEdit” when prompted.\n\n(\(error.localizedDescription))"
                } else {
                    alert.messageText = "MDEdit is now the default app for Markdown files"
                    alert.informativeText = "Double-clicking a .md file will open it here."
                }
                alert.runModal()
            }
        }
    }

    @objc func showRaw(_ sender: Any?) { Settings.mode = .raw }
    @objc func showFormatted(_ sender: Any?) { Settings.mode = .formatted }
    @objc func toggleMode(_ sender: Any?) { Settings.mode = Settings.mode == .raw ? .formatted : .raw }
    @objc func biggerText(_ sender: Any?) { Settings.fontSize += 1 }
    @objc func smallerText(_ sender: Any?) { Settings.fontSize -= 1 }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(makeDefault(_:)): item.state = isDefaultMarkdownApp() ? .on : .off
        case #selector(showRaw(_:)): item.state = Settings.mode == .raw ? .on : .off
        case #selector(showFormatted(_:)): item.state = Settings.mode == .formatted ? .on : .off
        default: break
        }
        return true
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenu {
            let m = NSMenu(title: title)
            build(m)
            let item = NSMenuItem()
            item.submenu = m
            main.addItem(item)
            return m
        }
        @discardableResult
        func add(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0, target: AnyObject? = nil) -> NSMenuItem {
            let item = m.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = tag
            item.target = target
            return item
        }

        _ = menu("MDEdit") { m in
            add(m, "About MDEdit", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            m.addItem(.separator())
            add(m, "Make Default App for Markdown Files", #selector(makeDefault(_:)), target: self)
            m.addItem(.separator())
            add(m, "Hide MDEdit", #selector(NSApplication.hide(_:)), "h")
            add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            m.addItem(.separator())
            add(m, "Quit MDEdit", #selector(NSApplication.terminate(_:)), "q")
        }
        _ = menu("File") { m in
            add(m, "New", #selector(NSDocumentController.newDocument(_:)), "n")
            add(m, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
            m.addItem(.separator())
            add(m, "Close", #selector(NSWindow.performClose(_:)), "w")
            add(m, "Save…", #selector(NSDocument.save(_:)), "s")
            add(m, "Save As…", #selector(NSDocument.saveAs(_:)), "S")
            add(m, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
        }
        _ = menu("Edit") { m in
            add(m, "Undo", Selector(("undo:")), "z")
            add(m, "Redo", Selector(("redo:")), "Z")
            m.addItem(.separator())
            add(m, "Cut", #selector(NSText.cut(_:)), "x")
            add(m, "Copy", #selector(NSText.copy(_:)), "c")
            add(m, "Paste", #selector(NSText.paste(_:)), "v")
            add(m, "Select All", #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            let find = #selector(NSTextView.performTextFinderAction(_:))
            add(m, "Find…", find, "f", tag: NSTextFinder.Action.showFindInterface.rawValue)
            add(m, "Find and Replace…", find, "f", [.command, .option],
                tag: NSTextFinder.Action.showReplaceInterface.rawValue)
            add(m, "Find Next", find, "g", tag: NSTextFinder.Action.nextMatch.rawValue)
            add(m, "Find Previous", find, "G", tag: NSTextFinder.Action.previousMatch.rawValue)
            add(m, "Use Selection for Find", find, "e", tag: NSTextFinder.Action.setSearchString.rawValue)
        }
        _ = menu("View") { m in
            add(m, "Raw Markdown", #selector(showRaw(_:)), "1", target: self)
            add(m, "Formatted", #selector(showFormatted(_:)), "2", target: self)
            add(m, "Toggle Raw / Formatted", #selector(toggleMode(_:)), "e", [.command, .shift], target: self)
            m.addItem(.separator())
            add(m, "Bigger Text", #selector(biggerText(_:)), "+", target: self)
            add(m, "Smaller Text", #selector(smallerText(_:)), "-", target: self)
        }
        NSApp.windowsMenu = menu("Window") { m in
            add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(m, "Zoom", #selector(NSWindow.performZoom(_:)))
        }
        return main
    }
}

// `MDEdit --make-default` sets the default handler without showing any UI.
if CommandLine.arguments.contains("--make-default") {
    makeDefaultMarkdownApp { error in
        if let error = error {
            FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        print("MDEdit is now the default app for Markdown files.")
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
