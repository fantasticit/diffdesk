import AppKit
import SwiftUI

struct NativeText: NSViewRepresentable {
    let text: String
    var editable = false
    var viewport: TextViewport?
    var jump: TextJump?
    var searchMarks: FileSearchMarks?
    var onChange: (String) -> Void = { _ in }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        var jumpID: UUID?
        let viewport = ViewportMonitor()
        let search = TextSearchHighlighter()
        init(_ onChange: @escaping (String) -> Void) { self.onChange = onChange }
        func textDidChange(_ notification: Notification) {
            if let textView = notification.object as? NSTextView {
                search.clear(in: textView, textWasEdited: true)
                onChange(textView.string)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScroll(text: text, editable: editable, delegate: context.coordinator)
    }

    static func makeScroll(text: String, editable: Bool = false, delegate: NSTextViewDelegate? = nil) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.backgroundColor = .textBackgroundColor
        view.textColor = .textColor
        view.insertionPointColor = .textColor
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 12, height: 10)
        view.isRichText = false
        view.importsGraphics = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.allowsUndo = editable
        view.isEditable = editable
        view.isSelectable = true
        view.delegate = delegate
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = editable
        view.allowsUndo = editable
        let state = context.coordinator
        if !view.string.utf8.elementsEqual(text.utf8) {
            state.search.clear(in: view)
            view.string = text
        }
        state.search.update(searchMarks, in: view, scroll: scroll) { $0.row == nil ? $0.range : nil }
        state.viewport.attach(viewport, to: scroll)
        state.viewport.schedule()
        guard let jump, state.jumpID != jump.id else { return }
        state.jumpID = jump.id
        let source = view.string as NSString
        var offset = 0
        for _ in 1..<max(1, jump.nativeLine) {
            guard offset < source.length else { break }
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
        }
        let range = source.lineRange(for: NSRange(location: offset, length: 0))
        scroll.revealText(range, in: view)
        if case .source = jump.target, range.length > 0 { view.showFindIndicator(for: range) }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.viewport.detach()
    }
}

enum DiffTone: Sendable {
    case addition, deletion

    var ink: NSColor {
        let added = self == .addition
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return added ? (dark ? NSColor(srgbRed: 0.54, green: 0.88, blue: 0.68, alpha: 1)
                                  : NSColor(srgbRed: 0.07, green: 0.38, blue: 0.22, alpha: 1))
                : (dark ? NSColor(srgbRed: 1, green: 0.62, blue: 0.68, alpha: 1)
                        : NSColor(srgbRed: 0.66, green: 0.16, blue: 0.26, alpha: 1))
        }
    }

    var tint: NSColor { self == .addition ? .systemGreen : .systemRed }

    var emphasis: NSColor {
        let added = self == .addition
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return (added ? NSColor.systemGreen : NSColor.systemRed).withAlphaComponent(dark ? 0.30 : 0.24)
        }
    }
}

struct ComparisonText: NSViewRepresentable {
    enum Presentation { case before, after, unified }

    let comparison: Comparison
    let presentation: Presentation
    let scrollLink: ScrollLink?
    let activeHunk: Range<Int>?
    let revealRevision: Int
    var viewport: TextViewport?
    var jump: TextJump?
    var searchMarks: FileSearchMarks?

    final class ScrollLink: NSObject {
        weak var lhs: NSScrollView?
        weak var rhs: NSScrollView?
        var syncing = false

        func attach(_ view: NSScrollView, left: Bool) {
            if left { lhs = view } else { rhs = view }
        }

        @objc func moved(_ notification: Notification) {
            guard !syncing, let lhs, let rhs, let clip = notification.object as? NSClipView else { return }
            let other = clip === lhs.contentView ? rhs : lhs
            var bounds = other.contentView.bounds
            bounds.origin.y = clip.bounds.origin.y
            let point = other.contentView.constrainBoundsRect(bounds).origin
            guard abs(point.y - other.contentView.bounds.origin.y) >= 0.5 else { return }
            syncing = true
            other.contentView.scroll(to: point)
            other.reflectScrolledClipView(other.contentView)
            syncing = false
        }
    }

    struct Span {
        let sourceRow: Int
        let range: NSRange
        let gutterRange: NSRange
        let tone: DiffTone?
        let left: Int?
        let right: Int?
    }

    final class Coordinator {
        var before: Data?
        var after: Data?
        var presentation: Presentation?
        var ignoresWhitespace = false
        var link: ScrollLink?
        var spans: [Span] = []
        var highlighted: Range<Int>?
        var revealRevision = 0
        var jumpID: UUID?
        let viewport = ViewportMonitor()
        let search = TextSearchHighlighter()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        NativeText.makeScroll(text: "")
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let state = context.coordinator
        if state.link !== scrollLink {
            if let old = state.link {
                NotificationCenter.default.removeObserver(old, name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            }
            state.link = scrollLink
            if let scrollLink {
                scrollLink.attach(scroll, left: presentation == .before)
                scroll.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(scrollLink, selector: #selector(ScrollLink.moved(_:)),
                                                       name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            }
        }
        if state.before != comparison.left.bytes || state.after != comparison.right.bytes
            || state.presentation != presentation || state.ignoresWhitespace != comparison.ignoresWhitespace {
            let scrollPosition = scroll.contentView.bounds.origin
            let output = makeText()
            state.search.clear(in: view)
            state.before = comparison.left.bytes
            state.after = comparison.right.bytes
            state.presentation = presentation
            state.ignoresWhitespace = comparison.ignoresWhitespace
            state.spans = output.spans
            state.highlighted = nil
            view.textStorage?.setAttributedString(output.text)
            scroll.contentView.scroll(to: scrollPosition)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        state.viewport.attach(viewport, to: scroll)
        state.viewport.schedule()
        updateHighlight(in: view, scroll: scroll, state: state)
        state.search.update(searchMarks, in: view, scroll: scroll) { match in
            guard let row = match.row, state.spans.indices.contains(row) else { return nil }
            let span = state.spans[row]
            let location = NSMaxRange(span.gutterRange) + match.range.location
            guard location + match.range.length <= NSMaxRange(span.range) else { return nil }
            return NSRange(location: location, length: match.range.length)
        }
        if let jump, jump.id != state.jumpID {
            state.jumpID = jump.id
            let span: Span?
            switch jump.target {
            case let .displayRow(index):
                span = state.spans.indices.contains(index) ? state.spans[index] : nil
            case let .source(line, side):
                span = state.spans.first { (side == .after ? $0.right : $0.left) == line }
            }
            if let span {
                scroll.revealText(span.range, in: view)
                if case let .source(_, side) = jump.target, span.range.length > 0,
                   presentation == .unified || (presentation == .before && side == .before)
                       || (presentation == .after && side == .after) {
                    view.showFindIndicator(for: span.range)
                }
            }
        }
    }

    private func makeText() -> (text: NSAttributedString, spans: [Span]) {
        let output = NSMutableAttributedString()
        var spans: [Span] = []
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 19
        paragraph.maximumLineHeight = 19
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph
        ]

        func gutter(_ value: Int?) -> String { value.map { String(format: "%5d", $0) } ?? "     " }

        func append(_ index: Int, before: Int?, after: Int?, code: String, tone: DiffTone?, emphasis: [NSRange]) {
            if output.length > 0 { output.append(NSAttributedString(string: "\n", attributes: attrs)) }
            let numbers = presentation == .unified ? gutter(before) + " " + gutter(after) :
                gutter(presentation == .before ? before : after)
            let mark = tone.map { $0 == .deletion ? " − " : " + " } ?? "   "
            let prefix = numbers + mark
            let codeOffset = prefix.utf16.count
            let line = NSMutableAttributedString(string: prefix + InlineDiff.displayText(code), attributes: attrs)
            line.addAttribute(.foregroundColor, value: tone?.ink ?? NSColor.secondaryLabelColor,
                              range: NSRange(location: 0, length: codeOffset))
            if let tone {
                line.addAttribute(.backgroundColor, value: tone.tint.withAlphaComponent(0.12),
                                  range: NSRange(location: 0, length: line.length))
                for range in emphasis {
                    line.addAttribute(.backgroundColor, value: tone.emphasis,
                                      range: NSRange(location: codeOffset + range.location, length: range.length))
                }
            }
            spans.append(Span(sourceRow: index, range: NSRange(location: output.length, length: line.length),
                              gutterRange: NSRange(location: output.length, length: codeOffset),
                              tone: tone, left: before, right: after))
            output.append(line)
        }

        if presentation == .unified {
            for line in comparison.unifiedLines() {
                append(line.sourceRow, before: line.left, after: line.right, code: line.code,
                       tone: line.tone, emphasis: line.emphasis)
            }
        } else {
            let left = presentation == .before
            for (index, row) in comparison.rows.enumerated() {
                let number = left ? row.leftNumber : row.rightNumber
                let tone: DiffTone? = row.changed && number != nil ? (left ? .deletion : .addition) : nil
                let emphasis = left ? row.emphasis?.left : row.emphasis?.right
                append(index, before: row.leftNumber, after: row.rightNumber,
                       code: (left ? row.left : row.right) ?? "", tone: tone, emphasis: emphasis ?? [])
            }
        }
        return (output, spans)
    }

    private func updateHighlight(in view: NSTextView, scroll: NSScrollView, state: Coordinator) {
        if state.highlighted != activeHunk, let layout = view.layoutManager {
            for span in state.spans {
                if state.highlighted?.contains(span.sourceRow) == true {
                    layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: span.gutterRange)
                }
                if activeHunk?.contains(span.sourceRow) == true, let tone = span.tone {
                    layout.addTemporaryAttribute(.backgroundColor, value: tone.tint.withAlphaComponent(0.26),
                                                 forCharacterRange: span.gutterRange)
                }
            }
            state.highlighted = activeHunk
        }
        guard state.revealRevision != revealRevision else { return }
        state.revealRevision = revealRevision
        guard let hunk = activeHunk, let span = state.spans.first(where: { hunk.contains($0.sourceRow) }) else { return }
        scroll.revealText(span.range, in: view)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.viewport.detach()
        if let link = coordinator.link {
            NotificationCenter.default.removeObserver(link, name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
    }
}
