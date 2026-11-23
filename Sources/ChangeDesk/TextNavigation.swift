import AppKit
import SwiftUI

enum SourceSide: String, CaseIterable, Identifiable {
    case before = "左侧"
    case after = "右侧"
    var id: Self { self }
}

struct TextJump {
    enum Target {
        case source(line: Int, side: SourceSide)
        case displayRow(Int)
    }

    let target: Target
    let id = UUID()

    var nativeLine: Int {
        switch target {
        case let .source(line, _): return line
        case let .displayRow(row): return row + 1
        }
    }
}

struct DiffDisplayLine {
    let sourceRow: Int
    let left: Int?
    let right: Int?
    let code: String
    let tone: DiffTone?
    var emphasis: [NSRange] = []
}

extension Comparison {
    func unifiedLines() -> [DiffDisplayLine] {
        var lines: [DiffDisplayLine] = []
        var cursor = 0

        func appendContext(_ range: Range<Int>) {
            for index in range {
                let row = rows[index]
                lines.append(DiffDisplayLine(sourceRow: index, left: row.leftNumber, right: row.rightNumber,
                                             code: row.right ?? row.left ?? "", tone: nil))
            }
        }

        for hunk in hunks {
            appendContext(cursor..<hunk.lowerBound)
            for index in hunk {
                let row = rows[index]
                if let code = row.left {
                    lines.append(DiffDisplayLine(sourceRow: index, left: row.leftNumber, right: nil,
                                                 code: code, tone: .deletion, emphasis: row.emphasis?.left ?? []))
                }
            }
            for index in hunk {
                let row = rows[index]
                if let code = row.right {
                    lines.append(DiffDisplayLine(sourceRow: index, left: nil, right: row.rightNumber,
                                                 code: code, tone: .addition, emphasis: row.emphasis?.right ?? []))
                }
            }
            cursor = hunk.upperBound
        }
        appendContext(cursor..<rows.count)
        return lines
    }
}

final class TextViewport: ObservableObject {
    struct Position: Equatable {
        let start: CGFloat
        let length: CGFloat
    }

    @Published private(set) var position = Position(start: 0, length: 1)
    fileprivate var source: UUID?

    fileprivate func publish(_ next: Position, source: UUID) {
        guard self.source == source, position != next else { return }
        position = next
    }
}

final class ViewportMonitor: NSObject {
    private let id = UUID()
    private weak var viewport: TextViewport?
    private weak var scroll: NSScrollView?
    private var pending = false

    func attach(_ viewport: TextViewport?, to scroll: NSScrollView) {
        guard self.viewport !== viewport || self.scroll !== scroll else { return }
        detach()
        guard let viewport else { return }
        self.viewport = viewport
        self.scroll = scroll
        viewport.source = id

        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: NSView.frameDidChangeNotification, object: clip)
        if let view = scroll.documentView {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: NSView.frameDidChangeNotification, object: view)
        }
        schedule()
    }

    @objc private func changed(_ notice: Notification) { schedule() }

    func schedule() {
        guard !pending, viewport != nil else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            guard let scroll = self.scroll, let viewport = self.viewport, let view = scroll.documentView else { return }
            let clip = scroll.contentView.bounds
            let height = max(view.bounds.height, clip.height, 1)
            viewport.publish(
                TextViewport.Position(start: max(0, min(1, clip.minY / height)), length: min(1, clip.height / height)),
                source: self.id
            )
        }
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        if viewport?.source == id { viewport?.source = nil }
        viewport = nil
        scroll = nil
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

extension NSScrollView {
    func revealText(_ range: NSRange, in view: NSTextView) {
        guard let layout = view.layoutManager, let container = view.textContainer else { return }
        layout.ensureLayout(forCharacterRange: range)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let y = range.length > 0 ? rect.minY : layout.extraLineFragmentRect.minY
        let clip = contentView
        var bounds = clip.bounds
        bounds.origin.y = max(0, y + view.textContainerOrigin.y - clip.bounds.height * 0.25)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(clip)
    }
}
