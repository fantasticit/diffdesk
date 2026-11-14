import Foundation

enum ChangeSearchScope: String, CaseIterable {
    case file = "文件"
    case directory = "目录"
}

struct SearchQuery {
    let text: String
    private let pattern: Pattern
    private let directoryPattern: Pattern

    init(_ input: String) {
        text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        pattern = Pattern(text)
        directoryPattern = Pattern(text.split(separator: "/").joined(separator: "/"))
    }

    var isEmpty: Bool { text.isEmpty }

    func ranked<T>(_ items: [T], score: (T) -> Int?) -> [T] {
        guard !isEmpty else { return items }
        return items.enumerated().compactMap { entry -> (item: T, score: Int, index: Int)? in
            guard let value = score(entry.element) else { return nil }
            return (entry.element, value, entry.offset)
        }.sorted {
            $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }.map(\.item)
    }

    func score(_ worktree: Worktree, relativePath: String) -> Int? {
        let absolute = worktree.url.path
        let home = NSHomeDirectory()
        let homeRelative = absolute.hasPrefix(home + "/") ? "~" + absolute.dropFirst(home.count) : absolute
        return [
            pattern.score(worktree.url.lastPathComponent, bonus: 320),
            pattern.score(worktree.branch, bonus: 190),
            pattern.score(relativePath, bonus: 80),
            pattern.score(absolute),
            pattern.score(homeRelative)
        ].compactMap { $0 }.max()
    }

    func score(_ change: Change, scope: ChangeSearchScope) -> Int? {
        [change.path, change.oldPath].compactMap { $0 }.enumerated().compactMap { index, path -> Int? in
            let value: Int?
            switch scope {
            case .file:
                let name = (path as NSString).lastPathComponent
                value = [pattern.score(name, bonus: 320), pattern.score(path, bonus: 80)]
                    .compactMap { $0 }.max()
            case .directory:
                let directory = (path as NSString).deletingLastPathComponent
                value = scoreDirectory(directory)
            }
            return value.map { $0 - index * 24 }
        }.max()
    }

    func scoreDirectory(_ path: String) -> Int? {
        if text == "." || directoryPattern.text.isEmpty { return path.isEmpty ? 4_000 : nil }
        let name = (path as NSString).lastPathComponent
        return [directoryPattern.score(name, bonus: 320), directoryPattern.score(path, bonus: 80)]
            .compactMap { $0 }.max()
    }

    private struct Pattern {
        let text: String
        let characters: [Character]

        init(_ query: String) {
            text = Self.fold(query)
            characters = Array(text)
        }

        private static func fold(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        }

        func score(_ raw: String, bonus: Int = 0) -> Int? {
            guard !characters.isEmpty, !raw.isEmpty else { return nil }
            let candidate = Self.fold(raw)
            if candidate == text { return 4_000 + bonus }
            if candidate.hasPrefix(text) { return 3_000 + bonus - min(150, candidate.count - characters.count) }
            if let range = candidate.range(of: text) {
                let offset = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
                let boundary = candidate[candidate.index(before: range.lowerBound)].isLetter || candidate[candidate.index(before: range.lowerBound)].isNumber ? 0 : 100
                return 2_000 + bonus + boundary - min(offset, 150)
            }

            var matched = 0
            var first = 0
            var previous = -1
            var boundaryBonus = 0
            var previousWasSeparator = true
            for (index, character) in candidate.enumerated() {
                if character == characters[matched] {
                    if matched == 0 { first = index }
                    if previousWasSeparator { boundaryBonus += 18 }
                    if index == previous + 1 { boundaryBonus += 8 }
                    previous = index
                    matched += 1
                    if matched == characters.count {
                        let gaps = index - first + 1 - matched
                        return 1_000 + bonus + min(boundaryBonus, 120) - min(gaps * 6 + first, 300)
                    }
                }
                previousWasSeparator = !character.isLetter && !character.isNumber
            }
            return nil
        }
    }
}
