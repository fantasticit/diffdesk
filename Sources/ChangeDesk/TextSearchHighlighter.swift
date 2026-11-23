import AppKit

final class TextSearchHighlighter {
    private var marks: FileSearchMarks?
    private var ranges: [NSRange] = []

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
    }

    func update(_ next: FileSearchMarks?, in view: NSTextView, scroll: NSScrollView,
                range resolve: (FileSearchRequest.Match) -> NSRange?) {
        guard next != marks else { return }
        let shouldReveal = next?.revealID != nil && next?.revealID != marks?.revealID
        clear(in: view)
        guard let next, let layout = view.layoutManager, let storage = view.textStorage else { return }
        marks = next
        for match in next.matches {
            guard let range = resolve(match), NSMaxRange(range) <= storage.length else { continue }
            let active = match == next.active
            layout.addTemporaryAttribute(.backgroundColor,
                                         value: active ? NSColor.findHighlightColor : Self.matchColor,
                                         forCharacterRange: range)
            if active {
                layout.addTemporaryAttribute(.foregroundColor, value: NSColor.black, forCharacterRange: range)
                if shouldReveal {
                    scroll.revealText(range, in: view)
                    view.scrollRangeToVisible(range)
                }
            }
            ranges.append(range)
        }
    }

    private static let matchColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(srgbRed: 0.37, green: 0.29, blue: 0.10, alpha: 1) :
            NSColor(srgbRed: 0.99, green: 0.91, blue: 0.68, alpha: 1)
    }
}
