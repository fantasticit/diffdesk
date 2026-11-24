import Darwin
import Foundation
import UniformTypeIdentifiers

enum GitError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum Group: String, CaseIterable, Sendable {
    case work = "未提交", branch = "已提交未合入"
}

enum Layer: String, CaseIterable, Identifiable, Sendable {
    case work = "未暂存", index = "已暂存", new = "未跟踪", conflict = "冲突", branch = "分支改动"
    var id: Self { self }
}

struct Change: Identifiable, Hashable, Sendable {
    let path: String
    let oldPath: String?
    let status: String
    let layers: [Layer]
    let group: Group
    var id: String { group.rawValue + "\0" + path }
}

struct Worktree: Identifiable, Sendable {
    let url: URL
    let branch: String
    let head: String?
    let base: String?
    let ancestor: String?
    let changes: [Change]
    var issue: String? = nil
    var pending = false
    private let changeIndexes: [String: Int]
    var id: URL { url }

    init(url: URL, branch: String, head: String?, base: String?, ancestor: String?, changes: [Change],
         issue: String? = nil, pending: Bool = false) {
        self.url = url
        self.branch = branch
        self.head = head
        self.base = base
        self.ancestor = ancestor
        self.changes = changes
        self.issue = issue
        self.pending = pending
        changeIndexes = Dictionary(changes.enumerated().map { ($0.element.id, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
    }

    func change(id: String?) -> Change? {
        guard let id, let index = changeIndexes[id] else { return nil }
        return changes[index]
    }
}

enum PreviewKind: Equatable, Sendable {
    case text, image, pdf, video, audio, archive, document, other

    init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if ["swift", "rs", "ts", "tsx", "jsx", "py", "go", "json", "toml", "yaml", "yml", "md", "sh", "ini", "log"].contains(ext) { self = .text }
        else if ["svg", "svgz"].contains(ext) { self = .image }
        else if type?.conforms(to: .image) == true { self = .image }
        else if type?.conforms(to: .pdf) == true { self = .pdf }
        else if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { self = .video }
        else if type?.conforms(to: .audio) == true { self = .audio }
        else if type?.conforms(to: .archive) == true || ["zip", "tar", "gz", "7z", "rar"].contains(ext) { self = .archive }
        else if ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "pages", "numbers", "key", "rtf", "rtfd"].contains(ext) {
            self = .document
        } else if type?.conforms(to: .text) == true {
            self = .text
        } else { self = .other }
    }

    var readsAsText: Bool { self == .text || self == .other }
}

final class PreviewFile: @unchecked Sendable {
    let url: URL
    private let container: URL?
    let revision: Date?

    init(url: URL, container: URL? = nil, revision: Date? = nil) {
        self.url = url
        self.container = container
        self.revision = revision
    }

    deinit {
        if let container { try? FileManager.default.removeItem(at: container) }
    }
}

struct Snapshot: Sendable {
    let label: String
    let present: Bool
    let text: String?
    let bytes: Data
    let kind: PreviewKind
    let preview: PreviewFile?
    let size: Int?
    let message: String?
    static let limit = 2 * 1024 * 1024
    static let historicalPreviewLimit = 256 * 1024 * 1024

    init(_ label: String, data: Data?, kind: PreviewKind = .text) {
        self.label = label
        present = data != nil
        bytes = data ?? Data()
        self.kind = kind
        size = data?.count
        preview = nil
        message = nil
        text = data.flatMap { data in
            guard kind.readsAsText, data.count <= Self.limit, !data.contains(0) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    init(_ label: String, kind: PreviewKind, size: Int? = nil, preview: PreviewFile? = nil, message: String? = nil) {
        self.label = label
        present = true
        bytes = Data()
        text = nil
        self.kind = kind
        self.preview = preview
        self.size = size
        self.message = message
    }
}

struct Comparison: Sendable {
    let left: Snapshot
    let right: Snapshot
    let disk: Snapshot
    private let diff: LineDiff

    var id: UUID { diff.id }
    var rows: [CodeRow] { diff.rows }
    var aligned: Bool { diff.aligned }
    var ignoresWhitespace: Bool { diff.ignoresWhitespace }
    var hunks: [Range<Int>] { diff.hunks }
    var additions: Int { diff.additions }
    var deletions: Int { diff.deletions }

    init(left: Snapshot, right: Snapshot, disk: Snapshot, rows: [CodeRow],
         aligned: Bool = true, ignoresWhitespace: Bool = false) {
        self.init(left: left, right: right, disk: disk,
                  diff: LineDiff(rows: rows, aligned: aligned, ignoresWhitespace: ignoresWhitespace))
    }

    private init(left: Snapshot, right: Snapshot, disk: Snapshot, diff: LineDiff) {
        self.left = left
        self.right = right
        self.disk = disk
        self.diff = diff
    }

    func reusingDiff(left: Snapshot, right: Snapshot, disk: Snapshot,
                     ignoresWhitespace: Bool) -> Comparison? {
        guard self.ignoresWhitespace == ignoresWhitespace,
              self.left.hasSameText(as: left), self.right.hasSameText(as: right) else { return nil }
        return Comparison(left: left, right: right, disk: disk, diff: diff)
    }

    private struct LineDiff: Sendable {
        let id = UUID()
        let rows: [CodeRow]
        let aligned: Bool
        let ignoresWhitespace: Bool
        let hunks: [Range<Int>]
        let additions: Int
        let deletions: Int

        init(rows: [CodeRow], aligned: Bool, ignoresWhitespace: Bool) {
            self.rows = rows
            self.aligned = aligned
            self.ignoresWhitespace = ignoresWhitespace
            var ranges: [Range<Int>] = []
            var start: Int?
            var additions = 0
            var deletions = 0
            for (index, row) in rows.enumerated() {
                if row.changed {
                    if start == nil { start = index }
                    if row.rightNumber != nil { additions += 1 }
                    if row.leftNumber != nil { deletions += 1 }
                } else if let first = start {
                    ranges.append(first..<index)
                    start = nil
                }
            }
            if let start { ranges.append(start..<rows.count) }
            hunks = ranges
            self.additions = additions
            self.deletions = deletions
        }
    }
}

private extension Snapshot {
    func hasSameText(as other: Snapshot) -> Bool {
        present == other.present && (text == nil) == (other.text == nil) && bytes == other.bytes
    }
}

struct CodeRow: Sendable {
    let left: String?
    let right: String?
    let leftNumber: Int?
    let rightNumber: Int?
    let changed: Bool
    var emphasis: InlineDiff? = nil
}

enum Git {
    static let executable = "/usr/bin/git"
    static let ignoreDirectories: Set<String> = [".git", "node_modules", ".build", ".venv", "vendor", ".pnpm-store", "dist", "build", "DerivedData", "__pycache__"]

    struct Result {
        let code: Int32
        let data: Data
        let error: String
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    static func run(_ args: [String], at directory: URL, allow: Set<Int32> = [0], writing: Bool = false, outputFile: FileHandle? = nil) throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = directory
        process.arguments = ["--literal-pathspecs"] + args
        var env = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_EXTERNAL_DIFF", "GIT_DIFF_OPTS"] { env.removeValue(forKey: key) }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        if !writing { env["GIT_OPTIONAL_LOCKS"] = "0" }
        process.environment = env
        let output = Pipe()
        let errors = Pipe()
        if let outputFile { process.standardOutput = outputFile }
        else { process.standardOutput = output }
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Drain stderr concurrently so a verbose command cannot block stdout.
        let errorRead = DispatchGroup()
        let errorBox = ErrorBuffer()
        errorRead.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.data = errors.fileHandleForReading.readDataToEndOfFile()
            errorRead.leave()
        }
        let data = outputFile == nil ? output.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        errorRead.wait()
        let error = String(decoding: errorBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard allow.contains(process.terminationStatus) else {
            throw GitError.message(error.isEmpty ? "Git 操作失败（\(process.terminationStatus)）" : error)
        }
        return Result(code: process.terminationStatus, data: data, error: error)
    }

    private final class ErrorBuffer: @unchecked Sendable { var data = Data() }

    static func discover(_ root: URL) -> [URL] {
        var pending = [root.path]
        var repos: [URL] = []
        while !Task.isCancelled, let folder = pending.popLast() {
            guard let stream = opendir(folder) else { continue }
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            while let entry = readdir(stream) {
                let name = withUnsafeBytes(of: &entry.pointee.d_name) { buffer in
                    String(bytes: buffer.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
                }
                guard let name else { continue }
                if name == ".git" {
                    repos.append(URL(fileURLWithPath: folder, isDirectory: true))
                } else if !name.hasPrefix("."), !ignoreDirectories.contains(name) {
                    let type = entry.pointee.d_type
                    if type == DT_DIR {
                        pending.append(prefix + name)
                    } else if type == DT_UNKNOWN {
                        let path = prefix + name
                        var info = stat()
                        if lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR { pending.append(path) }
                    }
                }
            }
            closedir(stream)
        }
        return repos.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func comparisonBase(_ preferred: String?, at url: URL) throws -> (ref: String, hash: String)? {
        if let preferred {
            let result = try run(["rev-parse", "--verify", "--end-of-options", preferred+"^{commit}"], at: url, allow: [0, 128])
            return result.code == 0 ? (preferred, result.text.trimmingCharacters(in: .newlines)) : nil
        }
        let remoteHead = "refs/remotes/origin/HEAD"
        let choices = ["refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master"]
        let result = try run(["for-each-ref", "--format=%(refname)%09%(objectname)%09%(symref)", "refs/remotes/origin"] + Array(choices.suffix(2)), at: url)
        var refs: [String: String] = [:]
        var target: String?
        for line in result.text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            refs[String(fields[0])] = String(fields[1])
            if fields[0] == remoteHead, !fields[2].isEmpty { target = String(fields[2]) }
        }
        for ref in [target].compactMap({ $0 }) + choices {
            if let hash = refs[ref] {
                let name = ref.hasPrefix("refs/remotes/") ? String(ref.dropFirst(13))
                    : ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
                return (name, hash)
            }
        }
        return nil
    }

    static func inspect(_ url: URL, preferredBase: String?) throws -> Worktree {
        let raw = try run(["status", "--porcelain=v2", "--branch", "--no-ahead-behind", "-z", "--untracked-files=all"], at: url).text
        let records = raw.split(separator: "\0", omittingEmptySubsequences: true)
        var branch = "分离 HEAD"
        var head: String?
        var changes: [Change] = []
        var i = 0
        while i < records.count {
            let record = records[i]
            i += 1
            if record.hasPrefix("# branch.head ") {
                let name = String(record.dropFirst(14))
                if name != "(detached)" { branch = name }
            } else if record.hasPrefix("# branch.oid ") {
                let hash = String(record.dropFirst(13))
                if hash != "(initial)" { head = hash }
            } else if record.hasPrefix("? ") {
                changes.append(Change(path: String(record.dropFirst(2)), oldPath: nil, status: "?", layers: [.new], group: .work))
            } else {
                let kind = record.first
                let split = kind == "1" ? 8 : kind == "2" ? 9 : kind == "u" ? 10 : 0
                guard split > 0 else { continue }
                let fields = record.split(separator: " ", maxSplits: split, omittingEmptySubsequences: true)
                guard fields.count == split + 1 else { continue }
                var original: String?
                if kind == "2", i < records.count { original = String(records[i]); i += 1 }
                let status = Array(fields[1])
                guard status.count == 2 else { continue }
                var layers: [Layer] = []
                if kind == "u" { layers = [.conflict] }
                else {
                    if status[1] != "." { layers.append(.work) }
                    if status[0] != "." { layers.append(.index) }
                }
                changes.append(Change(path: String(fields[split]), oldPath: original, status: String(fields[1]), layers: layers, group: .work))
            }
        }
        let base = try comparisonBase(preferredBase, at: url)
        var ancestor: String?
        if let base, let head {
            if base.hash == head {
                ancestor = head
            } else {
                let common = try run(["merge-base", base.hash, head], at: url, allow: [0, 1])
                if common.code == 0 { ancestor = common.text.trimmingCharacters(in: .newlines) }
            }
        }
        if let ancestor, let head, ancestor != head {
            let result = try run(["diff", "--no-ext-diff", "--no-textconv", "--name-status", "-z", "-M", ancestor, head, "--"], at: url)
            let tokens = result.text.split(separator: "\0")
            var index = 0
            while index + 1 < tokens.count {
                let status = String(tokens[index])
                let renamed = status.hasPrefix("R") || status.hasPrefix("C")
                if renamed && index + 2 >= tokens.count { break }
                changes.append(Change(path: String(tokens[index + (renamed ? 2 : 1)]), oldPath: renamed ? String(tokens[index + 1]) : nil, status: status, layers: [.branch], group: .branch))
                index += renamed ? 3 : 2
            }
        }
        return Worktree(url: url, branch: branch, head: head, base: base?.ref, ancestor: ancestor, changes: changes)
    }

    static func diskURL(_ path: String, in repo: URL) throws -> URL {
        let target = repo.appendingPathComponent(path)
        let prefix = repo.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard target.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            .appending("/").hasPrefix(prefix),
              !path.split(separator: "/").contains(".git"),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil else {
            throw GitError.message("该路径指向符号链接、Git 内部文件或工作树外部。")
        }
        return target
    }

    static func disk(_ path: String, in repo: URL) throws -> Snapshot {
        // A Git symlink stores its link target as the blob, not the linked file.
        let target = repo.appendingPathComponent(path)
        let prefix = repo.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard target.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            .appending("/").hasPrefix(prefix), !path.split(separator: "/").contains(".git") else {
            throw GitError.message("该文件不在工作树内。")
        }
        if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) {
            return Snapshot("工作区 · 符号链接", data: Data(link.utf8))
        }
        let url = try diskURL(path, in: repo)
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot("工作区", data: nil) }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        let kind = PreviewKind(path: path)
        guard values.isRegularFile == true else {
            return Snapshot("工作区", kind: kind, message: "该路径不是普通文件")
        }
        let size = values.fileSize ?? 0
        if kind.readsAsText, size <= Snapshot.limit {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Snapshot.limit + 1) ?? Data()
            let candidate = Snapshot("工作区", data: data, kind: kind)
            if candidate.text != nil { return candidate }
        }
        return Snapshot("工作区", kind: kind, size: size, preview: PreviewFile(url: url, revision: values.contentModificationDate))
    }

    static func blob(_ ref: String, _ path: String, _ title: String, at repo: URL) throws -> Snapshot {
        let kind = PreviewKind(path: path)
        let object = ref + ":" + path
        let size = try run(["cat-file", "-s", object], at: repo, allow: [0, 128])
        guard size.code == 0 else { return Snapshot(title, data: nil, kind: kind) }
        guard let count = Int(size.text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return Snapshot(title, kind: kind, message: "无法读取此 Git 对象")
        }
        guard count <= Snapshot.historicalPreviewLimit else {
            return Snapshot(title, kind: kind, size: count, message: "此历史文件超过 256 MiB")
        }
        if count <= Snapshot.limit && kind.readsAsText {
            let reply = try run(["cat-file", "blob", object], at: repo, allow: [0, 128])
            guard reply.code == 0 else { return Snapshot(title, kind: kind, message: "此 Git 对象不是普通文件") }
            let candidate = Snapshot(title, data: reply.data, kind: kind)
            if candidate.text != nil { return candidate }
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Bingyue-"+UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent((path as NSString).lastPathComponent)
        let preview = PreviewFile(url: url, container: dir)
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw GitError.message("无法创建历史版本预览文件")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let result = try run(["cat-file", "blob", object], at: repo, allow: [0, 128], outputFile: handle)
        guard result.code == 0 else { return Snapshot(title, kind: kind, message: "此 Git 对象不是普通文件") }
        return Snapshot(title, kind: kind, size: count, preview: preview)
    }

    static func compare(_ file: Change, layer: Layer, repo: Worktree, ignoresWhitespace: Bool = false,
                        previous: Comparison? = nil) throws -> Comparison {
        let current = try disk(file.path, in: repo.url)
        let old = file.oldPath ?? file.path
        let left: Snapshot
        let right: Snapshot
        switch layer {
        case .branch:
            guard let ancestor = repo.ancestor, let head = repo.head else { throw GitError.message("当前分支缺少可用的对比基准。") }
            left = try blob(ancestor, old, "共同祖先 · "+String(ancestor.prefix(7)), at: repo.url)
            right = try blob(head, file.path, "HEAD · "+String(head.prefix(7)), at: repo.url)
        case .index:
            left = try repo.head.map { try blob($0, old, "HEAD", at: repo.url) } ?? Snapshot("HEAD", data: nil)
            right = try blob("", file.path, "暂存区", at: repo.url)
        case .work:
            let workRename = file.status.last == "R" || file.status.last == "C"
            left = try blob("", workRename ? old : file.path, "暂存区", at: repo.url)
            right = current
        case .new:
            left = Snapshot("新增文件", data: nil)
            right = current
        case .conflict:
            left = try blob(":2", file.path, "冲突 · 当前分支", at: repo.url)
            right = current
        }
        let l = left.present ? left.text : (right.text == nil ? nil : "")
        let r = right.present ? right.text : (left.text == nil ? nil : "")
        guard let l, let r else {
            return Comparison(left: left, right: right, disk: current, rows: [])
        }
        if let reused = previous?.reusingDiff(left: left, right: right, disk: current,
                                             ignoresWhitespace: ignoresWhitespace) {
            return reused
        }
        let result = try align(l, r, ignoresWhitespace: ignoresWhitespace)
        return Comparison(left: left, right: right, disk: current, rows: result.0,
                          aligned: result.1, ignoresWhitespace: ignoresWhitespace)
    }

    static func align(_ left: String, _ right: String, ignoresWhitespace: Bool = false) throws -> ([CodeRow], Bool) {
        // components preserves every blank line and the terminal newline. Split on LF
        // rather than Character because Swift treats a CRLF pair as one grapheme.
        let a = left.isEmpty ? [] : left.components(separatedBy: "\n")
        let b = right.isEmpty ? [] : right.components(separatedBy: "\n")
        guard max(a.count, b.count) <= 30_000 else { return ([], false) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("diffplus-"+UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old")
        let new = dir.appendingPathComponent("new")
        // Emit one physical line for each display line, including an empty terminal row.
        try (a.isEmpty ? "" : a.joined(separator: "\n")+"\n").write(to: old, atomically: false, encoding: .utf8)
        try (b.isEmpty ? "" : b.joined(separator: "\n")+"\n").write(to: new, atomically: false, encoding: .utf8)
        var args = ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--text", "--unified=0"]
        if ignoresWhitespace { args.append("--ignore-all-space") }
        let patch = try run(args + ["--", "old", "new"], at: dir, allow: [0, 1]).text
        let regex = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        var rows: [CodeRow] = []
        var i = 0, j = 0
        var emphasisBudget = 1_000_000
        func append(_ lhs: Bool, _ rhs: Bool, changed: Bool) {
            var row = CodeRow(left: lhs ? a[i] : nil, right: rhs ? b[j] : nil,
                              leftNumber: lhs ? i+1 : nil, rightNumber: rhs ? j+1 : nil, changed: changed)
            if changed, let left = row.left, let right = row.right, emphasisBudget > 0 {
                row.emphasis = InlineDiff.compare(left, right, budget: &emphasisBudget)
            }
            rows.append(row)
            if lhs { i += 1 }
            if rhs { j += 1 }
        }
        for line in patch.split(separator: "\n") where line.hasPrefix("@@ ") {
            try Task.checkCancellation()
            let s = String(line) as NSString
            guard let match = regex.firstMatch(in: String(line), range: NSRange(location: 0, length: s.length)) else { continue }
            func number(_ group: Int, default missing: Int = 1) -> Int {
                let range = match.range(at: group)
                return range.location == NSNotFound ? missing : (Int(s.substring(with: range)) ?? missing)
            }
            let ac = number(2), bc = number(4)
            let ai = number(1) - (ac > 0 ? 1 : 0)
            let bi = number(3) - (bc > 0 ? 1 : 0)
            guard ai >= i, bi >= j, ai-i == bi-j, ai+ac <= a.count, bi+bc <= b.count else { return ([], false) }
            while i < ai { append(true, true, changed: false) }
            for k in 0..<max(ac, bc) { append(k < ac, k < bc, changed: true) }
        }
        guard a.count-i == b.count-j else { return ([], false) }
        while i < a.count { append(true, true, changed: false) }
        return (rows, true)
    }
}

extension Git {
    static func indexState(at url: URL) throws -> Data {
        try run(["diff", "--cached", "--raw", "--no-abbrev", "--no-renames", "-z", "--"], at: url).data
    }

    static func stagedPaths(at url: URL) throws -> [String] {
        try run(["diff", "--cached", "--name-status", "--no-renames", "-z", "--"], at: url).text.split(separator: "\0").enumerated().compactMap { $0.offset.isMultiple(of: 2) ? nil : String($0.element) }
    }
}
