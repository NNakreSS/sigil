import AppKit
import SigilCore
import SwiftUI

/// Bridge between the SwiftUI editor window and the AppKit text view: cursor position, jumps, find, close requests.
@MainActor
@Observable
final class EditorController {
    @ObservationIgnored weak var textView: SigilTextView?
    @ObservationIgnored weak var ruler: LineNumberRuler?
    var line = 1
    var column = 1
    var selectionLength = 0
    var language: CodeLanguage = .plain
    var diagnostics: [Diagnostic] = [] {
        didSet { ruler?.diagnostics = Dictionary(diagnostics.map { ($0.line, $0.severity) }, uniquingKeysWith: { a, b in a == .error ? a : b }); textView?.markDiagnostics(diagnostics) }
    }
    @ObservationIgnored var onSave: (() -> Void)?
    @ObservationIgnored var onGoToLine: (() -> Void)?
    @ObservationIgnored var isDirty: () -> Bool = { false }

    func goTo(line n: Int) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        var start = 0
        var current = 1
        while current < n, start < ns.length {
            let r = ns.lineRange(for: NSRange(location: start, length: 0))
            start = NSMaxRange(r)
            current += 1
        }
        let range = ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0))
        let target = NSRange(location: range.location, length: 0)
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(target)
        tv.scrollRangeToVisible(range)
        if range.length > 0 { tv.showFindIndicator(for: NSRange(location: range.location, length: max(0, range.length - 1))) }
    }

    func find(_ action: NSTextFinder.Action) { textView?.find(action) }
    func toggleComment() { textView?.toggleComment() }
}

// MARK: - Text view

final class SigilTextView: NSTextView {
    weak var controller: EditorController?
    var language: CodeLanguage = .plain
    private var diagnosticRanges: [(NSRange, Diagnostic.Severity)] = []

    private var indentUnit: String { language.indentWidth == 0 ? "\t" : String(repeating: " ", count: language.indentWidth) }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case ([.command], "f"), ([.control], "f"): find(.showFindInterface)
        case ([.command, .option], "f"): find(.showReplaceInterface)
        case ([.command], "g"): find(.nextMatch)
        case ([.command, .shift], "g"): find(.previousMatch)
        case ([.command], "e"): find(.setSearchString)
        case ([.command], "/"): toggleComment()
        case ([.command], "l"): controller?.onGoToLine?()
        case ([.command], "d"): duplicateLines()
        case ([.command], "s"): controller?.onSave?()
        case ([.command], "]"): shiftLines(right: true)
        case ([.command], "["): shiftLines(right: false)
        case ([.command], "x"): cut(nil)
        case ([.command], "c"): copy(nil)
        case ([.command], "v"): paste(nil)
        case ([.command], "a"): selectAll(nil)
        case ([.command], "z"): undoManager?.undo()
        case ([.command, .shift], "z"): undoManager?.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        window?.makeFirstResponder(self)
        performFindPanelAction(item)
    }

    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        if sel.length > 0, ns.substring(with: sel).contains("\n") { shiftLines(right: true); return }
        if indentUnit == "\t" { insertText("\t", replacementRange: sel); return }
        // Spaces up to the next indent stop.
        let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        let col = sel.location - lineStart
        let w = language.indentWidth
        insertText(String(repeating: " ", count: w - col % w), replacementRange: sel)
    }

    override func insertBacktab(_ sender: Any?) { shiftLines(right: false) }

    /// Keeps the indentation of the current line; one level more after `:` (YAML, Python) or an opening bracket.
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let before = ns.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))
        var indent = String(before.prefix { $0 == " " || $0 == "\t" })
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let opens = trimmed.hasSuffix("{") || trimmed.hasSuffix("[") || trimmed.hasSuffix("(")
            || (trimmed.hasSuffix(":") && [.yaml, .python].contains(language))
        if opens { indent += indentUnit }
        insertText("\n" + indent, replacementRange: sel)
    }

    // MARK: Line operations (undoable)

    private func replace(_ range: NSRange, with text: String, select: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let select { setSelectedRange(select) }
    }

    private func selectedLines() -> (NSRange, [String]) {
        let ns = string as NSString
        var range = ns.lineRange(for: selectedRange())
        // A selection ending at the start of a line does not include that line.
        let sel = selectedRange()
        if sel.length > 0, NSMaxRange(sel) == range.location + range.length, NSMaxRange(sel) > 0,
           ns.character(at: NSMaxRange(sel) - 1) == 10, range.length > 0 {
            range = ns.lineRange(for: NSRange(location: sel.location, length: sel.length - 1))
        }
        var text = ns.substring(with: range)
        let trailing = text.hasSuffix("\n")
        if trailing { text.removeLast() }
        return (range, text.components(separatedBy: "\n") + (trailing ? ["\u{0}"] : []))
    }

    private func join(_ lines: [String]) -> String {
        var l = lines
        if l.last == "\u{0}" { l.removeLast(); return l.joined(separator: "\n") + "\n" }
        return l.joined(separator: "\n")
    }

    func shiftLines(right: Bool) {
        let (range, lines) = selectedLines()
        let unit = indentUnit
        let changed = lines.map { line -> String in
            if line == "\u{0}" { return line }
            if right { return line.isEmpty ? line : unit + line }
            if line.hasPrefix(unit) { return String(line.dropFirst(unit.count)) }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.drop(while: { $0 == " " }).prefix(line.count)).count < line.count
                ? String(line.dropFirst(min(line.prefix { $0 == " " }.count, max(1, language.indentWidth)))) : line
        }
        let text = join(changed)
        replace(range, with: text, select: NSRange(location: range.location, length: (text as NSString).length))
    }

    func toggleComment() {
        guard let prefix = language.lineComment else { NSSound.beep(); return }
        let (range, lines) = selectedLines()
        let content = lines.filter { $0 != "\u{0}" && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return }
        let allCommented = content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
        let minIndent = content.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let changed = lines.map { line -> String in
            if line == "\u{0}" || line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if allCommented {
                guard let r = line.range(of: prefix) else { return line }
                var after = line[r.upperBound...]
                if after.hasPrefix(" ") { after = after.dropFirst() }
                return String(line[..<r.lowerBound]) + after
            }
            let i = line.index(line.startIndex, offsetBy: minIndent)
            return String(line[..<i]) + prefix + " " + line[i...]
        }
        let text = join(changed)
        replace(range, with: text, select: NSRange(location: range.location, length: (text as NSString).length))
    }

    func duplicateLines() {
        let ns = string as NSString
        let range = ns.lineRange(for: selectedRange())
        var block = ns.substring(with: range)
        if !block.hasSuffix("\n") { block = "\n" + block; replace(NSRange(location: NSMaxRange(range), length: 0), with: block) }
        else { replace(NSRange(location: NSMaxRange(range), length: 0), with: block) }
        setSelectedRange(NSRange(location: NSMaxRange(range) + (block.hasPrefix("\n") ? 1 : 0), length: 0))
    }

    // MARK: Drawing

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        updateCursor()
    }

    private func updateCursor() {
        guard let controller else { return }
        let ns = string as NSString
        let loc = min(selectedRange().location, ns.length)
        var line = 1
        var i = 0
        let head = ns.substring(to: loc)
        for b in head.utf16 where b == 10 { line += 1 }
        let lineStart = ns.lineRange(for: NSRange(location: loc, length: 0)).location
        i = loc - lineStart
        if controller.line != line { controller.line = line }
        if controller.column != i + 1 { controller.column = i + 1 }
        if controller.selectionLength != selectedRange().length { controller.selectionLength = selectedRange().length }
    }

    /// Soft band behind the line with the cursor.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, let lm = layoutManager, let tc = textContainer else { return }
        let ns = string as NSString
        let loc = selectedRange().location
        var lineRect: NSRect
        if loc >= ns.length, ns.length == 0 || ns.character(at: ns.length - 1) == 10 {
            lineRect = lm.extraLineFragmentRect
        } else {
            let glyph = lm.glyphIndexForCharacter(at: min(loc, max(0, ns.length - 1)))
            lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            _ = tc
        }
        guard lineRect.height > 0 else { return }
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect.origin.y += textContainerOrigin.y
        NSColor(Color.accentInk).withAlphaComponent(0.07).setFill()
        lineRect.fill()
    }

    // MARK: Colours (temporary attributes: colour only, no relayout)

    func applyHighlight(_ tokens: [Token]) {
        guard let lm = layoutManager else { return }
        let full = NSRange(location: 0, length: (string as NSString).length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        for t in tokens where NSMaxRange(t.range) <= full.length {
            lm.addTemporaryAttribute(.foregroundColor, value: SyntaxPalette.color(t.kind), forCharacterRange: t.range)
        }
        markDiagnostics(nil)
    }

    /// Tints the lines with problems.
    func markDiagnostics(_ list: [Diagnostic]?) {
        guard let lm = layoutManager else { return }
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let list {
            var starts: [Int] = [0]
            for (i, b) in string.utf16.enumerated() where b == 10 { starts.append(i + 1) }
            diagnosticRanges = list.compactMap { d in
                guard d.line >= 1, d.line <= starts.count else { return nil }
                let r = ns.lineRange(for: NSRange(location: starts[d.line - 1], length: 0))
                return (r, d.severity)
            }
        }
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        for (r, sev) in diagnosticRanges where NSMaxRange(r) <= full.length {
            let c = sev == .error ? NSColor(Color.cinnabar) : NSColor(Color.amberInk)
            lm.addTemporaryAttribute(.backgroundColor, value: c.withAlphaComponent(0.12), forCharacterRange: r)
        }
    }
}

enum SyntaxPalette {
    static func color(_ kind: TokenKind) -> NSColor {
        let dark = ThemeStore.shared.current.isDark
        switch kind {
        case .comment: return dark ? NSColor(white: 0.56, alpha: 1) : NSColor(white: 0.45, alpha: 1)
        case .string: return NSColor(Color.verdigris)
        case .number: return NSColor(Color.amberInk)
        case .keyword: return NSColor(Color.accentInk)
        case .key: return dark ? AppTheme.hex(0x7DD3FC) : AppTheme.hex(0x0369A1)
        case .variable: return dark ? AppTheme.hex(0xF0ABFC) : AppTheme.hex(0xA21CAF)
        case .section: return dark ? AppTheme.hex(0xFDE68A) : AppTheme.hex(0x92400E)
        case .constant: return NSColor(Color.cinnabar).blended(withFraction: 0.25, of: dark ? .white : .black) ?? NSColor(Color.cinnabar)
        case .punctuation: return .secondaryLabelColor
        case .error: return NSColor(Color.cinnabar)
        case .warning: return NSColor(Color.amberInk)
        }
    }
}

// MARK: - Line numbers

final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var diagnostics: [Int: Diagnostic.Severity] = [:] { didSet { needsDisplay = true } }
    private var lineStarts: [Int] = [0]
    var fontSize: CGFloat = 12 { didSet { updateThickness() } }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        clipsToBounds = true
        updateThickness()
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func textChanged() {
        var starts = [0]
        if let s = textView?.string {
            for (i, b) in s.utf16.enumerated() where b == 10 { starts.append(i + 1) }
        }
        lineStarts = starts
        updateThickness()
        needsDisplay = true
    }

    private var font: NSFont { .monospacedDigitSystemFont(ofSize: max(9, fontSize - 1), weight: .regular) }

    private func updateThickness() {
        let digits = max(3, String(lineStarts.count).count)
        let w = ("8" as NSString).size(withAttributes: [.font: font]).width
        let t = ceil(CGFloat(digits) * w + 22)
        if abs(ruleThickness - t) > 0.5 { ruleThickness = t }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        NSColor(Color.vellum).setFill()
        bounds.fill()
        NSColor(Color.hairline).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let ns = tv.string as NSString
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let currentLine = tv.selectedRange().location
        // First line at or before the visible range (binary search).
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if lineStarts[mid] <= chars.location { lo = mid } else { hi = mid - 1 } }
        let origin = tv.textContainerOrigin.y
        var i = lo
        while i < lineStarts.count {
            let start = lineStarts[i]
            if start > NSMaxRange(chars) && i > lo { break }
            var lineRect: NSRect
            if start >= ns.length {
                lineRect = lm.extraLineFragmentRect
                if lineRect.height == 0 { break }
            } else {
                lineRect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let y = convert(NSPoint(x: 0, y: lineRect.minY + origin), from: tv).y
            let next = i + 1 < lineStarts.count ? lineStarts[i + 1] : ns.length + 1
            let isCurrent = currentLine >= start && currentLine < next
            let sev = diagnostics[i + 1]
            let color: NSColor = sev == .error ? NSColor(Color.cinnabar) : sev == .warning ? NSColor(Color.amberInk)
                : isCurrent ? .labelColor : .tertiaryLabelColor
            let label = "\(i + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = label.size(withAttributes: attrs)
            let fontH = (tv.font?.ascender ?? 10) - (tv.font?.descender ?? -3)
            let ty = y + (min(lineRect.height, fontH + 2) - size.height) / 2
            label.draw(at: NSPoint(x: bounds.width - size.width - 10, y: ty), withAttributes: attrs)
            if sev != nil {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 4, y: ty + size.height / 2 - 2.5, width: 5, height: 5)).fill()
            }
            i += 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Click a number: select that line.
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let p = tv.convert(event.locationInWindow, from: nil)
        let idx = lm.characterIndex(for: NSPoint(x: 0, y: p.y - tv.textContainerOrigin.y), in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
        let r = (tv.string as NSString).lineRange(for: NSRange(location: idx, length: 0))
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(r)
    }
}

// MARK: - SwiftUI wrapper

struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    var wrap: Bool
    var fontSize: Double
    var language: CodeLanguage
    let controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = SigilTextView(usingTextLayoutManager: false)
        tv.controller = controller
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.usesFontPanel = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(Color.vellum)
        tv.textColor = .textColor
        tv.insertionPointColor = NSColor(Color.accentInk)
        tv.selectedTextAttributes = [.backgroundColor: NSColor(Color.accentInk).withAlphaComponent(0.3)]
        tv.string = text
        scroll.documentView = tv

        let ruler = LineNumberRuler(textView: tv, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        controller.textView = tv
        controller.ruler = ruler
        context.coordinator.textView = tv
        context.coordinator.ruler = ruler
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true

        apply(tv, scroll, ruler)
        ruler.textChanged()
        context.coordinator.scheduleHighlight(immediately: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? SigilTextView, let ruler = scroll.verticalRulerView as? LineNumberRuler else { return }
        context.coordinator.parent = self
        var changed = false
        if tv.string != text {
            tv.string = text
            tv.undoManager?.removeAllActions()
            ruler.textChanged()
            changed = true
        }
        if tv.language != language { tv.language = language; changed = true }
        apply(tv, scroll, ruler)
        if changed { context.coordinator.scheduleHighlight(immediately: true) }
    }

    private func apply(_ tv: SigilTextView, _ scroll: NSScrollView, _ ruler: LineNumberRuler) {
        tv.language = language
        tv.isEditable = editable
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if tv.font != font {
            tv.font = font
            tv.typingAttributes[.font] = font
            ruler.fontSize = fontSize
        }
        scroll.hasHorizontalScroller = !wrap
        tv.isHorizontallyResizable = !wrap
        tv.textContainer?.widthTracksTextView = wrap
        if wrap {
            tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            tv.frame.size.width = scroll.contentSize.width
        } else {
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        weak var textView: SigilTextView?
        weak var ruler: LineNumberRuler?
        private var generation = 0
        private var pending: Task<Void, Never>?

        init(_ parent: CodeTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            ruler?.textChanged()
            scheduleHighlight()
        }

        @objc func scrolled() { ruler?.needsDisplay = true }

        /// Colours off the main thread, applied only if the text has not changed meanwhile.
        func scheduleHighlight(immediately: Bool = false) {
            generation += 1
            let gen = generation
            pending?.cancel()
            guard let tv = textView else { return }
            let text = tv.string
            let language = parent.language
            let delay: UInt64 = immediately ? 0 : (text.utf16.count > 100_000 ? 350 : 120) * 1_000_000
            pending = Task { [weak self] in
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                if Task.isCancelled { return }
                let tokens = await Task.detached(priority: .userInitiated) { Highlighter.tokens(text, language: language) }.value
                guard let self, gen == self.generation, let tv = self.textView else { return }
                tv.applyHighlight(tokens)
            }
        }
    }
}
