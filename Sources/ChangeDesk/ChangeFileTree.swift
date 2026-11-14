import Foundation

struct ChangeFileTree {
    struct Entry: Identifiable {
        enum Item {
            case folder(path: String, count: Int)
            case file(Change)
        }

        let item: Item
        let depth: Int

        var id: String {
            switch item {
            case .folder(let path, _): "folder:" + path
            case .file(let change): change.id
            }
        }
    }

    private struct Directory {
        var folders: Set<String> = []
        var files: [Change] = []
        var count = 0
    }

    private var directories: [String: Directory] = [:]

    init(changes: [Change], query: SearchQuery) {
        var matchingFolders: [String: Bool] = [:]
        for change in changes {
            let parts = change.path.split(separator: "/").dropLast().map(String.init)
            var ancestors = [""]
            for part in parts {
                let parent = ancestors.last ?? ""
                ancestors.append(parent.isEmpty ? part : parent + "/" + part)
            }
            if !query.isEmpty, query.score(change, scope: .file) == nil,
               !ancestors.contains(where: { path in
                   if let matches = matchingFolders[path] { return matches }
                   let matches = query.scoreDirectory(path) != nil
                   matchingFolders[path] = matches
                   return matches
               }), query.score(change, scope: .directory) == nil { continue }

            directories[ancestors.last ?? "", default: Directory()].files.append(change)
            for (parent, child) in zip(ancestors, ancestors.dropFirst()) {
                directories[parent, default: Directory()].folders.insert(child)
                directories[child, default: Directory()].count += 1
            }
        }
    }

    func rows(isExpanded: (String) -> Bool) -> [Entry] {
        var result: [Entry] = []
        func append(_ path: String, depth: Int) {
            guard let directory = directories[path] else { return }
            for child in directory.folders.sorted(by: Self.ordered) {
                result.append(Entry(item: .folder(path: child, count: directories[child]?.count ?? 0), depth: depth))
                if isExpanded(child) { append(child, depth: depth + 1) }
            }
            let files = directory.files.sorted {
                $0.path == $1.path ? $0.group == .work && $1.group == .branch : Self.ordered($0.path, $1.path)
            }
            result.append(contentsOf: files.map { Entry(item: .file($0), depth: depth) })
        }
        append("", depth: 0)
        return result
    }

    private static func ordered(_ lhs: String, _ rhs: String) -> Bool {
        let order = lhs.localizedStandardCompare(rhs)
        return order == .orderedSame ? lhs < rhs : order == .orderedAscending
    }
}
