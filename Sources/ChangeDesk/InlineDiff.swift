import Foundation

struct InlineDiff: Sendable {
    let left: [NSRange]
    let right: [NSRange]

    static func displayText(_ code: String) -> String {
        code.replacingOccurrences(of: "\r", with: "")
    }

    static func compare(_ left: String, _ right: String, budget: inout Int) -> InlineDiff? {
        let leftLength = left.utf16.count
        let rightLength = right.utf16.count
        guard (1...256).contains(leftLength), (1...256).contains(rightLength) else { return nil }
        // Bound the cumulative work for generated files with many rewritten lines.
        let cost = leftLength * rightLength
        guard cost <= budget else { return nil }
        budget -= cost

        let before = Array(displayText(left))
        let after = Array(displayText(right))
        let difference = after.difference(from: before)
        guard !difference.isEmpty, difference.removals.count < before.count else { return nil }

        func offsets(_ changes: [CollectionDifference<Character>.Change]) -> Set<Int> {
            Set(changes.map { change in
                switch change {
                case let .remove(offset, _, _), let .insert(offset, _, _): offset
                }
            })
        }

        func ranges(in characters: [Character], changed: Set<Int>) -> [NSRange] {
            var result: [NSRange] = []
            var offset = 0
            for (index, character) in characters.enumerated() {
                let length = String(character).utf16.count
                if changed.contains(index) {
                    if let last = result.last, NSMaxRange(last) == offset {
                        result[result.count - 1].length += length
                    } else {
                        result.append(NSRange(location: offset, length: length))
                    }
                }
                offset += length
            }
            return result
        }

        return InlineDiff(left: ranges(in: before, changed: offsets(difference.removals)),
                          right: ranges(in: after, changed: offsets(difference.insertions)))
    }
}
