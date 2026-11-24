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
        var content: String
        var jumpID: UUID?
        let viewport = ViewportMonitor()
        let search = TextSearchHighlighter()
        init(text: String, onChange: @escaping (String) -> Void) {
            content = text
            self.onChange = onChange
        }
        func textDidChange(_ notification: Notification) {
            if let textView = notification.object as? NSTextView {
                search.clear(in: textView, textWasEdited: true)
                content = textView.string
                onChange(content)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: text, onChange: onChange) }

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
        configure(view, editable: editable)
        view.textColor = .textColor
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.delegate = delegate
        view.layoutManager?.allowsNonContiguousLayout = true
        view.string = text
        return scroll
    }

    static func configure(_ view: NSTextView, editable: Bool) {
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.backgroundColor = .textBackgroundColor
        view.insertionPointColor = .textColor
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
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = editable
        view.allowsUndo = editable
        let state = context.coordinator
        if !state.content.utf8.elementsEqual(text.utf8) {
            state.search.clear(in: view)
            view.string = text
            state.content = text
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

struct ComparisonText: View {
    typealias Presentation = DiffTextDocument.Presentation

    let comparison: Comparison
    let presentation: Presentation
    let scrollLink: ScrollLink?
    let activeHunk: Range<Int>?
    let revealRevision: Int
    var viewport: TextViewport?
    var jump: TextJump?
    var searchMarks: FileSearchMarks?
    @DeskState private var prepared: DiffTextDocument?

    var body: some View {
        let key = DiffTextDocument.Key(comparisonID: comparison.id, presentation: presentation)
        ComparisonTextView(document: prepared, ready: prepared?.key == key,
                           presentation: presentation, scrollLink: scrollLink,
                           activeHunk: activeHunk, revealRevision: revealRevision,
                           viewport: viewport, jump: jump, searchMarks: searchMarks)
            .overlay {
                if prepared == nil {
                    ProgressView().controlSize(.small).accessibilityLabel("正在加载代码差异")
                }
            }
            .task(id: key) {
                let comparison = comparison
                let worker = Task.detached(priority: .userInitiated) {
                    try DiffTextDocument.build(comparison, key: key)
                }
                let result = try? await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let result else { return }
                prepared = result
            }
    }

    final class ScrollLink: NSObject {
        private weak var lhs: NSScrollView?
        private weak var rhs: NSScrollView?
        private var syncing = false

        func attach(_ view: NSScrollView, left: Bool) {
            let peer = left ? rhs : lhs
            if left { lhs = view } else { rhs = view }
            if let peer { synchronize(from: peer.contentView, to: view) }
        }

        func detach(_ view: NSScrollView) {
            if lhs === view { lhs = nil }
            if rhs === view { rhs = nil }
        }

        @objc func moved(_ notification: Notification) {
            guard !syncing, let lhs, let rhs, let clip = notification.object as? NSClipView else { return }
            let other = clip === lhs.contentView ? rhs : lhs
            synchronize(from: clip, to: other)
        }

        private func synchronize(from clip: NSClipView, to other: NSScrollView) {
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

}

private struct ComparisonTextView: NSViewRepresentable {
    let document: DiffTextDocument?
    let ready: Bool
    let presentation: ComparisonText.Presentation
    let scrollLink: ComparisonText.ScrollLink?
    let activeHunk: Range<Int>?
    let revealRevision: Int
    let viewport: TextViewport?
    let jump: TextJump?
    let searchMarks: FileSearchMarks?

    final class Coordinator {
        var document: DiffTextDocument?
        var link: ComparisonText.ScrollLink?
        var highlighted: Range<Int>?
        var revealRevision = 0
        var jumpID: UUID?
        let viewport = ViewportMonitor()
        let search = TextSearchHighlighter()

        func detachLink(from scroll: NSScrollView) {
            guard let link else { return }
            NotificationCenter.default.removeObserver(link, name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            link.detach(scroll)
            self.link = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        NativeText.makeScroll(text: "")
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard var view = scroll.documentView as? NSTextView else { return }
        let state = context.coordinator
        if state.link !== scrollLink { state.detachLink(from: scroll) }
        if let document, state.document?.key != document.key {
            let scrollPosition = scroll.contentView.bounds.origin
            state.detachLink(from: scroll)
            state.search.clear(in: view)
            state.highlighted = nil
            state.jumpID = nil
            if let layout = document.splitLayout {
                state.viewport.detach()
                let replacement = NSTextView(frame: view.frame, textContainer: layout.container)
                NativeText.configure(replacement, editable: false)
                scroll.documentView = replacement
                view = replacement
            } else {
                view.textStorage?.setAttributedString(document.text)
            }
            state.document = document
            scroll.contentView.scroll(to: scrollPosition)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        state.viewport.attach(viewport, to: scroll)
        state.viewport.schedule()
        guard ready, let document else { return }
        if state.link == nil, let scrollLink {
            state.link = scrollLink
            scrollLink.attach(scroll, left: presentation == .before)
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(scrollLink, selector: #selector(ComparisonText.ScrollLink.moved(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        let spans = document.spans
        updateHighlight(in: view, scroll: scroll, state: state, document: document)
        state.search.update(searchMarks, in: view, scroll: scroll) { match in
            guard let row = match.row, spans.indices.contains(row) else { return nil }
            let span = spans[row]
            let location = NSMaxRange(span.gutterRange) + match.range.location
            guard location + match.range.length <= NSMaxRange(span.range) else { return nil }
            return NSRange(location: location, length: match.range.length)
        }
        if let jump, jump.id != state.jumpID {
            state.jumpID = jump.id
            let span: DiffTextDocument.Span?
            switch jump.target {
            case let .displayRow(index):
                span = spans.indices.contains(index) ? spans[index] : nil
            case let .source(line, side):
                span = spans.first { (side == .after ? $0.right : $0.left) == line }
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

    private func updateHighlight(in view: NSTextView, scroll: NSScrollView,
                                 state: Coordinator, document: DiffTextDocument) {
        if state.highlighted != activeHunk, let layout = view.layoutManager {
            if let previous = state.highlighted {
                for span in document.displaySpans(for: previous) {
                    layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: span.gutterRange)
                }
            }
            if let activeHunk {
                for span in document.displaySpans(for: activeHunk) {
                    if let tone = span.tone {
                        layout.addTemporaryAttribute(.backgroundColor, value: tone.tint.withAlphaComponent(0.26),
                                                     forCharacterRange: span.gutterRange)
                    }
                }
            }
            state.highlighted = activeHunk
        }
        guard state.revealRevision != revealRevision else { return }
        state.revealRevision = revealRevision
        guard let hunk = activeHunk, let span = document.displaySpans(for: hunk).first else { return }
        scroll.revealText(span.range, in: view)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.viewport.detach()
        coordinator.detachLink(from: scroll)
    }
}
