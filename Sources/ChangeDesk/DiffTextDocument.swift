import AppKit

// Created on one worker and handed off to the main thread without concurrent access.
struct DiffTextDocument: @unchecked Sendable {
    enum Presentation: Sendable { case before, after, unified }

    struct Key: Equatable, Sendable {
        let comparisonID: UUID
        let presentation: Presentation
    }

    struct Span {
        let sourceRow: Int
        let range: NSRange
        let gutterRange: NSRange
        let tone: DiffTone?
        let left: Int?
        let right: Int?
    }

    let key: Key
    let text: NSAttributedString
    let spans: [Span]
    let splitLayout: SplitLayout?
    private let unifiedHunks: [Range<Int>: Range<Int>]

    struct SplitLayout {
        let storage: NSTextStorage
        let container: NSTextContainer

        init(text: NSAttributedString) {
            storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            layout.backgroundLayoutEnabled = false
            container = NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                               height: CGFloat.greatestFiniteMagnitude))
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            // Split panes need exact vertical geometry to keep shared rows aligned.
            layout.ensureLayout(for: container)
        }
    }

    func displaySpans(for hunk: Range<Int>) -> ArraySlice<Span> {
        if key.presentation == .unified {
            return unifiedHunks[hunk].map { spans[$0] } ?? []
        }
        return spans[hunk.clamped(to: spans.indices)]
    }

    static func build(_ comparison: Comparison, key: Key) throws -> Self {
        let unified = key.presentation == .unified
        let left = key.presentation == .before
        let lineCount = comparison.rows.count
        var plain = ""
        var spans: [Span] = []
        var emphasized: [(DiffTone, NSRange)] = []
        var offset = 0
        spans.reserveCapacity(lineCount)
        let codeSize = unified ? comparison.left.bytes.count + comparison.right.bytes.count :
            (left ? comparison.left.bytes.count : comparison.right.bytes.count)
        plain.reserveCapacity(codeSize + lineCount * (unified ? 14 : 8))

        func gutter(_ value: Int?) -> String {
            guard let value else { return "     " }
            let number = String(value)
            return String(repeating: " ", count: max(0, 5 - number.count)) + number
        }

        func append(_ row: Int, before: Int?, after: Int?, code: String,
                    tone: DiffTone?, emphasis: [NSRange]) throws {
            if spans.count.isMultiple(of: 256) { try Task.checkCancellation() }
            if !spans.isEmpty {
                plain.append("\n")
                offset += 1
            }
            let numbers = unified ? gutter(before) + " " + gutter(after) : gutter(left ? before : after)
            let mark = tone.map { $0 == .deletion ? " − " : " + " } ?? "   "
            let prefix = numbers + mark
            let code = InlineDiff.displayText(code)
            let gutterLength = prefix.utf16.count
            let length = gutterLength + code.utf16.count
            plain += prefix
            plain += code
            spans.append(Span(sourceRow: row, range: NSRange(location: offset, length: length),
                              gutterRange: NSRange(location: offset, length: gutterLength),
                              tone: tone, left: before, right: after))
            if let tone {
                for range in emphasis {
                    emphasized.append((tone, NSRange(location: offset + gutterLength + range.location,
                                                     length: range.length)))
                }
            }
            offset += length
        }

        if unified {
            for line in comparison.unifiedLines() {
                try append(line.sourceRow, before: line.left, after: line.right, code: line.code,
                           tone: line.tone, emphasis: line.emphasis)
            }
        } else {
            for (index, row) in comparison.rows.enumerated() {
                let code = left ? row.left : row.right
                let tone: DiffTone? = row.changed && code != nil ? (left ? .deletion : .addition) : nil
                let emphasis = left ? row.emphasis?.left : row.emphasis?.right
                try append(index, before: row.leftNumber, after: row.rightNumber,
                           code: code ?? "", tone: tone, emphasis: emphasis ?? [])
            }
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 19
        paragraph.maximumLineHeight = 19
        let output = NSMutableAttributedString(string: plain, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph.copy() as! NSParagraphStyle
        ])
        let addedInk = DiffTone.addition.ink
        let removedInk = DiffTone.deletion.ink
        let addedBackground = DiffTone.addition.tint.withAlphaComponent(0.12)
        let removedBackground = DiffTone.deletion.tint.withAlphaComponent(0.12)
        let addedEmphasis = DiffTone.addition.emphasis
        let removedEmphasis = DiffTone.deletion.emphasis
        output.beginEditing()
        for (index, span) in spans.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let ink: NSColor
            switch span.tone {
            case .addition: ink = addedInk
            case .deletion: ink = removedInk
            case nil: ink = .secondaryLabelColor
            }
            output.addAttribute(.foregroundColor, value: ink, range: span.gutterRange)
            if let tone = span.tone {
                output.addAttribute(.backgroundColor, value: tone == .addition ? addedBackground : removedBackground,
                                    range: span.range)
            }
        }
        for (tone, range) in emphasized {
            output.addAttribute(.backgroundColor, value: tone == .addition ? addedEmphasis : removedEmphasis, range: range)
        }
        output.endEditing()

        var unifiedHunks: [Range<Int>: Range<Int>] = [:]
        if unified {
            var cursor = 0
            for hunk in comparison.hunks {
                while cursor < spans.count && spans[cursor].sourceRow < hunk.lowerBound { cursor += 1 }
                let begin = cursor
                while cursor < spans.count && hunk.contains(spans[cursor].sourceRow) { cursor += 1 }
                unifiedHunks[hunk] = begin..<cursor
            }
        }
        try Task.checkCancellation()
        let text = NSAttributedString(attributedString: output)
        let splitLayout = unified ? nil : SplitLayout(text: text)
        return Self(key: key, text: text, spans: spans, splitLayout: splitLayout, unifiedHunks: unifiedHunks)
    }
}
