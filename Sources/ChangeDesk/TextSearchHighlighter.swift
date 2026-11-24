import AppKit

final class TextSearchHighlighter {
    private var marks: FileSearchMarks?
    private var ranges: [NSRange] = []
    private var activeRange: NSRange?

    func clear(in view: NSTextView, textWasEdited: Bool = false) {
        guard marks != nil, let layout = view.layoutManager else { return }
        if textWasEdited {
            let length = view.textStorage?.length ?? 0
            ranges = length == 0 ? [] : [NSRange(location: 0, length: length)]
        }
        for range in ranges {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }
        marks = nil
        ranges = []
        activeRange = nil
    }

    func update(_ next: FileSearchMarks?, in view: NSTextView, scroll: NSScrollView,
                range resolve: (FileSearchRequest.Match) -> NSRange?) {
        guard next != marks else { return }
        let shouldReveal = next?.revealID != nil && next?.revealID != marks?.revealID
        guard let next, let layout = view.layoutManager, let length = view.textStorage?.length else {
            clear(in: view)
            return
        }

        if marks?.matches != next.matches {
            clear(in: view)
            ranges = next.matches.compactMap(resolve).filter { NSMaxRange($0) <= length }
            for range in ranges {
                layout.addTemporaryAttribute(.backgroundColor, value: Self.matchColor, forCharacterRange: range)
            }
        }

        let active = resolve(next.active).flatMap { NSMaxRange($0) <= length ? $0 : nil }
        if activeRange != active {
            if let previous = activeRange {
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: previous)
                layout.addTemporaryAttribute(.backgroundColor, value: Self.matchColor, forCharacterRange: previous)
            }
            if let active {
                layout.addTemporaryAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black],
                                              forCharacterRange: active)
            }
            activeRange = active
        }
        marks = next
        if shouldReveal, let active {
            scroll.revealText(active, in: view)
            view.scrollRangeToVisible(active)
        }
    }

    private static let matchColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(srgbRed: 0.37, green: 0.29, blue: 0.10, alpha: 1) :
            NSColor(srgbRed: 0.99, green: 0.91, blue: 0.68, alpha: 1)
    }
}
