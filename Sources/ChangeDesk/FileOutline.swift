import Foundation

struct OutlineSymbol: Identifiable, Sendable {
    enum Kind: Sendable { case heading, type, function, property }

    let line: Int
    let title: String
    let depth: Int
    let kind: Kind

    var id: Int { line }
}

enum FileOutline {
    static func parse(_ text: String, path: String) -> [OutlineSymbol] {
        let lines = text.components(separatedBy: "\n")
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdx": return markdown(lines)
        case "swift": return code(lines, .swift)
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts": return code(lines, .javascript)
        case "py", "pyw", "pyi": return code(lines, .python)
        case "rs": return code(lines, .rust)
        case "go": return code(lines, .go)
        default: return []
        }
    }

    private static func markdown(_ lines: [String]) -> [OutlineSymbol] {
        var result: [OutlineSymbol] = []
        var levels: [Int] = []
        var fence: (mark: Character, length: Int)?
        var previous: (Int, String)?

        func append(level: Int, line: Int, title: String) {
            while let last = levels.last, last >= level { levels.removeLast() }
            result.append(OutlineSymbol(line: line, title: title, depth: levels.count, kind: .heading))
            levels.append(level)
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            guard leading.count <= 3, !leading.contains("\t") else { previous = nil; continue }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let repeatCount = trimmed.prefix { $0 == marker }.count
                if repeatCount >= 3 {
                    if let active = fence {
                        if marker == active.mark && repeatCount >= active.length
                            && trimmed.dropFirst(repeatCount).allSatisfy(\.isWhitespace) {
                            fence = nil
                        }
                    } else {
                        fence = (marker, repeatCount)
                    }
                    previous = nil
                    continue
                }
            }
            guard fence == nil else { continue }

            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first?.isWhitespace == true {
                let content = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                let title = content.replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
                if !title.isEmpty { append(level: hashes, line: index + 1, title: title) }
                previous = nil
            } else if let first = trimmed.first, first == "=" || first == "-",
                      trimmed.allSatisfy({ $0 == first }), let candidate = previous {
                append(level: first == "=" ? 1 : 2, line: candidate.0, title: candidate.1)
                previous = nil
            } else {
                previous = trimmed.isEmpty || trimmed.hasPrefix(">") ? nil : (index + 1, trimmed)
            }
        }
        return result
    }

    private enum Language { case swift, javascript, python, rust, go }

    private static func code(_ lines: [String], _ language: Language) -> [OutlineSymbol] {
        let declarations: [(OutlineSymbol.Kind, String)]
        switch language {
        case .swift:
            declarations = [
                (.type, #"^(?:(?:@\w+(?:\([^)]*\))?|\w+(?:\(set\))?)\s+)*(?:struct|class|enum|protocol|actor|extension)\s+([\w.]+)"#),
                (.function, #"^(?:(?:@\w+(?:\([^)]*\))?|\w+(?:\(set\))?)\s+)*func\s+([\w]+)\s*(?:[<(]|$)"#),
                (.function, #"^(?:(?:@\w+|\w+)\s+)*(init)[?!]?\s*[<(]"#),
                (.property, #"^(?:(?:@\w+(?:\([^)]*\))?|\w+(?:\(set\))?)\s+)*(?:var|let)\s+([\w]+)"#)
            ]
        case .javascript:
            declarations = [
                (.type, #"^(?:(?:export|default|declare|abstract)\s+)*(?:class|interface|type|enum|namespace)\s+([\w$]+)"#),
                (.function, #"^(?:(?:export|default|async|declare)\s+)*function\b\s*\*?\s*([\w$]+)"#),
                (.function, #"^(?:export\s+)?(?:const|let|var)\s+([\w$]+)[^=]*=\s*(?:async\s*)?.*=>"#),
                (.function, #"^(?:(?:public|private|protected|static|async|readonly|get|set|override)\s+)*([\w$]+)\s*\([^;]*\)\s*(?::[^\{]+)?\s*\{"#)
            ]
        case .python:
            declarations = [
                (.type, #"^class\s+(\w+)"#),
                (.function, #"^(?:async\s+)?def\s+(\w+)\s*\("#)
            ]
        case .rust:
            declarations = [
                (.type, #"^(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|trait|mod|type|impl)\s+(\w+)"#),
                (.function, #"^(?:(?:pub(?:\([^)]*\))?|async|unsafe|const)\s+)*fn\s+(\w+)"#)
            ]
        case .go:
            declarations = [
                (.type, #"^type\s+(\w+)"#),
                (.function, #"^func\s+(?:\([^)]*\)\s+)?(\w+)\s*(?:\(|\[)"#)
            ]
        }
        let patterns = declarations.compactMap { kind, expression in
            (try? NSRegularExpression(pattern: expression)).map { (kind, $0) }
        }

        struct Scope {
            let index: Int
            let kind: OutlineSymbol.Kind
        }

        var results: [OutlineSymbol] = []
        var scopes: [Scope] = []
        var depth = 0
        var blockComment = false
        var pending: OutlineSymbol.Kind?
        var multilineQuote: String?
        for (index, original) in lines.enumerated() {
            let trim = original.trimmingCharacters(in: .whitespacesAndNewlines)
            if language == .python, let quote = multilineQuote {
                if trim.contains(quote) { multilineQuote = nil }
                continue
            }
            if language == .python, let quote = ["\"\"\"", "'''"].first(where: { trim.hasPrefix($0) }) {
                if !trim.dropFirst(3).contains(quote) { multilineQuote = quote }
                continue
            }
            let wasComment = blockComment
            let movement = braces(in: original, blockComment: &blockComment)
            if trim.isEmpty || trim.hasPrefix("//") || trim.hasPrefix("/*") || wasComment || trim.hasPrefix("#") { continue }

            let leading = original.prefix { $0 == " " || $0 == "\t" }.reduce(0) {
                $0 + ($1 == "\t" ? 4 : 1)
            }
            let level = language == .python ? leading : depth
            if language == .python {
                while let scope = scopes.last, scope.index >= level { scopes.removeLast() }
            }
            var declared: OutlineSymbol.Kind?
            let range = NSRange(location: 0, length: trim.utf16.count)
            for (kind, pattern) in patterns {
                guard let match = pattern.firstMatch(in: trim, range: range),
                      let capture = Range(match.range(at: 1), in: trim) else { continue }
                let title = String(trim[capture])
                if language == .javascript, pattern == patterns.last?.1,
                   scopes.last?.kind != .type || ["if", "while", "for", "switch", "catch"].contains(title) { continue }
                if kind == .property, scopes.contains(where: { $0.kind == .function }) { continue }
                results.append(OutlineSymbol(line: index + 1, title: title, depth: scopes.count, kind: kind))
                declared = kind
                break
            }

            if language == .python {
                if let declared { scopes.append(Scope(index: level, kind: declared)) }
            } else {
                let next = max(0, depth + movement)
                if next > depth, let opens = declared ?? pending {
                    scopes.append(Scope(index: depth + 1, kind: opens))
                }
                if let declared, declared != .property, movement == 0, !trim.contains("{"), !trim.hasSuffix(";") {
                    pending = declared
                } else {
                    pending = nil
                }
                while let scope = scopes.last, scope.index > next { scopes.removeLast() }
                depth = next
            }
            if results.count == 2_000 { break }
        }
        return results
    }

    private static func braces(in line: String, blockComment: inout Bool) -> Int {
        var chars = line.makeIterator()
        var current = chars.next()
        var count = 0
        var quote: Character?
        while let char = current {
            current = chars.next()
            if blockComment {
                if char == "*", current == "/" {
                    blockComment = false
                    current = chars.next()
                }
            } else if let active = quote {
                if char == "\\" { current = chars.next() }
                else if char == active { quote = nil }
            } else if char == "/", current == "/" {
                break
            } else if char == "/", current == "*" {
                blockComment = true
                current = chars.next()
            } else if char == "\"" || char == "'" || char == "`" {
                quote = char
            } else if char == "{" {
                count += 1
            } else if char == "}" {
                count -= 1
            }
        }
        return count
    }
}
