import AppKit
import SwiftUI

struct NativeText: NSViewRepresentable {
    let text: String
    var editable = false
    var onChange: (String) -> Void = { _ in }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        init(_ onChange: @escaping (String) -> Void) { self.onChange = onChange }
        func textDidChange(_ notification: Notification) {
            if let textView = notification.object as? NSTextView { onChange(textView.string) }
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
        if !view.string.utf8.elementsEqual(text.utf8) { view.string = text }
    }
}

struct ComparisonText: NSViewRepresentable {
    let comparison: Comparison
    let left: Bool
    let scrollLink: ScrollLink
    let activeHunk: Range<Int>?
    let revealRevision: Int

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
            var point = other.contentView.bounds.origin
            point.y = clip.bounds.origin.y
            if abs(point.y - other.contentView.bounds.origin.y) < 0.5 { return }
            syncing = true
            other.contentView.scroll(to: point)
            other.reflectScrolledClipView(other.contentView)
            syncing = false
        }
    }

    final class Coordinator {
        var data: Data?
        var other: Data?
        var aligned: Bool?
        var link: ScrollLink?
        var rows: [NSRange] = []
        var highlighted: Range<Int>?
        var revealRevision = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        NativeText.makeScroll(text: "")
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        if coordinator.link !== scrollLink {
            if let old = coordinator.link { NotificationCenter.default.removeObserver(old, name: NSView.boundsDidChangeNotification, object: scroll.contentView) }
            coordinator.link = scrollLink
            scrollLink.attach(scroll, left: left)
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(scrollLink, selector: #selector(ScrollLink.moved(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        let snapshot = left ? comparison.left : comparison.right
        let other = left ? comparison.right : comparison.left
        guard coordinator.data != snapshot.bytes || coordinator.other != other.bytes || coordinator.aligned != comparison.aligned else {
            updateHighlight(in: view, scroll: scroll, coordinator: coordinator)
            return
        }
        coordinator.rows = []
        coordinator.highlighted = nil
        coordinator.data = snapshot.bytes
        coordinator.other = other.bytes
        coordinator.aligned = comparison.aligned
        let output = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let foreground = NSColor.textColor
        let lineColor = NSColor.secondaryLabelColor
        let markColor: NSColor = left ? .systemRed : .systemGreen
        let space = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        space.minimumLineHeight = 17
        space.maximumLineHeight = 17
        let scrollPosition = scroll.contentView.bounds.origin
        if comparison.rows.isEmpty {
            output.append(NSAttributedString(string: snapshot.text ?? snapshot.message ?? "",
                                             attributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: space]))
        } else {
            for (index, row) in comparison.rows.enumerated() {
                let number = left ? row.leftNumber : row.rightNumber
                let code = (left ? row.left : row.right) ?? ""
                let lineNumber = number.map { String(format: "%5d", $0) } ?? "     "
                let mark = row.changed && number != nil ? (left ? " − " : " + ") : "   "
                let prefix = lineNumber + mark
                let line = NSMutableAttributedString(string: prefix + code.replacingOccurrences(of: "\r", with: "") + (index+1 == comparison.rows.count ? "" : "\n"),
                                                     attributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: space])
                line.addAttribute(.foregroundColor, value: lineColor, range: NSRange(location: 0, length: prefix.utf16.count))
                if row.changed, number != nil {
                    line.addAttribute(.backgroundColor, value: markColor.withAlphaComponent(0.14), range: NSRange(location: 0, length: line.length))
                }
                coordinator.rows.append(NSRange(location: output.length, length: line.length))
                output.append(line)
            }
        }
        view.textStorage?.setAttributedString(output)
        scroll.contentView.scroll(to: scrollPosition)
        scroll.reflectScrolledClipView(scroll.contentView)
        updateHighlight(in: view, scroll: scroll, coordinator: coordinator)
    }

    private func updateHighlight(in view: NSTextView, scroll: NSScrollView, coordinator: Coordinator) {
        let changed = coordinator.highlighted != activeHunk
        if changed, let layout = view.layoutManager {
            if let old = coordinator.highlighted {
                for index in old where coordinator.rows.indices.contains(index) {
                    layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: coordinator.rows[index])
                }
            }
            if let activeHunk {
                let color: NSColor = left ? .systemRed : .systemGreen
                for index in activeHunk where coordinator.rows.indices.contains(index) {
                    if left ? comparison.rows[index].left != nil : comparison.rows[index].right != nil {
                        layout.addTemporaryAttribute(.backgroundColor, value: color.withAlphaComponent(0.29),
                                                     forCharacterRange: coordinator.rows[index])
                    }
                }
            }
            coordinator.highlighted = activeHunk
        }
        guard coordinator.revealRevision != revealRevision else { return }
        coordinator.revealRevision = revealRevision
        guard let index = activeHunk?.lowerBound, coordinator.rows.indices.contains(index),
              let layout = view.layoutManager, let container = view.textContainer else { return }
        let range = coordinator.rows[index]
        layout.ensureLayout(forCharacterRange: range)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let clip = scroll.contentView
        var point = clip.bounds.origin
        point.y = max(0, rect.minY + view.textContainerOrigin.y - clip.bounds.height * 0.25)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: point, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let link = coordinator.link { NotificationCenter.default.removeObserver(link, name: NSView.boundsDidChangeNotification, object: scroll.contentView) }
    }
}
