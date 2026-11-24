import Foundation

enum FileSearchSurface: Equatable, Sendable {
    case before, after, unified, full
}

enum FileSearchDocument: Equatable, Sendable {
    case text(String)
    case diff(Comparison, FileSearchSurface)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.text(left), .text(right)):
            left == right && left.utf8.elementsEqual(right.utf8)
        case let (.diff(left, leftSurface), .diff(right, rightSurface)):
            leftSurface == rightSurface && left.id == right.id
        default:
            false
        }
    }
}

struct FileSearchRequest: Equatable, Sendable {
    let query: String
    let surface: FileSearchSurface
    let document: FileSearchDocument

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.surface == rhs.surface && lhs.query.utf8.elementsEqual(rhs.query.utf8) && lhs.document == rhs.document
    }

    struct Match: Equatable, Sendable {
        let row: Int?
        let range: NSRange
    }

    func matches() throws -> [Match] {
        guard !query.isEmpty else { return [] }
        var result: [Match] = []
        func search(_ code: String, row: Int? = nil) throws {
            try Task.checkCancellation()
            let text = code as NSString
            var remaining = NSRange(location: 0, length: text.length)
            while remaining.length > 0 {
                let range = text.range(of: query, options: [.literal, .caseInsensitive], range: remaining)
                guard range.location != NSNotFound, range.length > 0 else { break }
                result.append(Match(row: row, range: range))
                if result.count.isMultiple(of: 256) { try Task.checkCancellation() }
                let end = NSMaxRange(range)
                remaining = NSRange(location: end, length: text.length - end)
            }
        }

        switch document {
        case .text(let text):
            try search(text)
        case .diff(let comparison, .unified):
            for (index, line) in comparison.unifiedLines().enumerated() {
                try search(InlineDiff.displayText(line.code), row: index)
            }
        case let .diff(comparison, side):
            for (index, row) in comparison.rows.enumerated() {
                if let code = side == .before ? row.left : row.right {
                    try search(InlineDiff.displayText(code), row: index)
                }
            }
        }
        return result
    }
}

struct FileSearchResult {
    let request: FileSearchRequest
    let matches: [FileSearchRequest.Match]
}

struct FileSearchMarks: Equatable {
    let matches: ArraySlice<FileSearchRequest.Match>
    let active: FileSearchRequest.Match
    let revealID: UUID?

    init(result: FileSearchResult, selection: Int, revealID: UUID?) {
        // Keep all matches navigable while bounding the drawing work for very common terms.
        let limit = 256
        let start = (selection / limit) * limit
        matches = result.matches[start..<min(start + limit, result.matches.count)]
        active = result.matches[selection]
        self.revealID = revealID
    }
}
