import AppKit
import CoreServices
import SwiftUI

@MainActor
final class Workspace: ObservableObject {
    @Published var directory: URL?
    @Published var repos: [Worktree] = []
    @Published var repoID: URL?
    @Published var fileID: String?
    @Published var layer: Layer = .work
    @Published var comparison: Comparison?
    @Published var mode: Mode = .compare
    @Published var scanning = false
    @Published var loading = false
    @Published var busy = false
    @Published var issue: String?
    @Published var fileIssue: String?
    @Published var notice: String?
    @Published var editing = false
    @Published var draft = ""
    @Published var layoutRevision = UUID()
    @Published private(set) var ignoresWhitespace: Bool
    @Published private(set) var recentWorkspaces: [URL]

    enum Mode: String, CaseIterable { case compare = "并排", unified = "行内", full = "文件" }
    enum FullVersion: String, CaseIterable { case left = "左侧版本", right = "右侧版本", disk = "工作区" }
    @Published var fullVersion: FullVersion = .right
    var repo: Worktree? { repos.first { $0.id == repoID } }
    var file: Change? { repo?.change(id: fileID) }
    var hasDraft: Bool { editing && Data(draft.utf8) != comparison?.disk.bytes }
    var fullSnapshot: Snapshot? {
        switch fullVersion {
        case .left: return comparison?.left
        case .right: return comparison?.right
        case .disk: return comparison?.disk
        }
    }
    var hasSearchableText: Bool {
        if mode == .full { return editing || fullSnapshot?.text != nil }
        return comparison?.left.text != nil || comparison?.right.text != nil
    }
    var canEdit: Bool {
        guard let disk = comparison?.disk else { return false }
        return disk.present && disk.text != nil && !disk.label.contains("符号链接")
    }

    private var watch: DirectoryWatch?
    private let environment: UserDefaults
    private var refreshToken = UUID()
    private var loadToken = UUID()
    private var delayedRefresh: Task<Void, Never>?
    private var refreshAgain = false
    private var manualRefreshQueued = false
    private var scanTask: Task<Void, Never>?
    private var fileLoadTask: Task<Void, Never>?
    private var changedPaths: Set<String> = []

    init(environment: UserDefaults = .standard) {
        self.environment = environment
        ignoresWhitespace = environment.bool(forKey: "ignoresWhitespace")
        let stored = environment.stringArray(forKey: "recentWorkspaces") ?? []
        let last = environment.string(forKey: "workspace").map { [$0] } ?? []
        var seen: Set<String> = []
        recentWorkspaces = (last + stored).filter { seen.insert($0).inserted }.prefix(8).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    func start() {
        guard directory == nil else { return }
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--workspace"), args.indices.contains(flag+1) {
            open(URL(fileURLWithPath: args[flag+1], isDirectory: true))
        } else if let path = environment.string(forKey: "workspace"), FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    func chooseDirectory() {
        guard leaveEditor(), !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func openRecent(_ url: URL) {
        guard url != directory, !busy else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            issue = "无法打开工作区：\(url.path)"
            return
        }
        if leaveEditor() { open(url) }
    }

    func open(_ url: URL) {
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        scanTask?.cancel()
        fileLoadTask?.cancel()
        delayedRefresh?.cancel()
        refreshAgain = false
        manualRefreshQueued = false
        refreshToken = UUID()
        loadToken = UUID()
        directory = root
        environment.set(root.path, forKey: "workspace")
        recentWorkspaces = Array(([root] + recentWorkspaces.filter { $0 != root }).prefix(8))
        environment.set(recentWorkspaces.map(\.path), forKey: "recentWorkspaces")
        repos = []
        repoID = nil
        fileID = nil
        comparison = nil
        issue = nil
        notice = nil
        scanning = false
        editing = false
        changedPaths = []
        watch = DirectoryWatch(url: root) { [weak self] paths in
            Task { @MainActor in
                guard self?.directory == root else { return }
                self?.scheduleRefresh(paths: paths)
            }
        }
        refresh()
    }

    func scheduleRefresh(paths: [String] = []) {
        changedPaths.formUnion(paths)
        delayedRefresh?.cancel()
        delayedRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            self?.refresh(automatic: true)
        }
    }

    func priorBase(for url: URL) -> String? {
        environment.dictionary(forKey: "bases")?[url.path] as? String
    }

    func setBase(_ ref: String) {
        guard let repo, leaveEditor() else { return }
        var bases = environment.dictionary(forKey: "bases") ?? [:]
        let value = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        bases[repo.url.path] = value.isEmpty ? nil : value
        environment.set(bases, forKey: "bases")
        refresh()
    }

    func refresh(automatic: Bool = false) {
        guard let directory else { return }
        if scanning || busy {
            refreshAgain = true
            manualRefreshQueued = manualRefreshQueued || !automatic
            return
        }
        scanning = true
        issue = nil
        let token = UUID()
        refreshToken = token
        let previous = Dictionary(uniqueKeysWithValues: repos.map { ($0.url, $0) })
        let pathsChanged = changedPaths
        changedPaths = []
        let priority = repoID
        let bases = environment.dictionary(forKey: "bases")?.compactMapValues { $0 as? String } ?? [:]
        scanTask = Task.detached(priority: automatic ? .utility : .userInitiated) { [weak self] in
            let needsDiscovery = !automatic || previous.isEmpty || pathsChanged.contains { path in
                !previous.keys.contains(where: { path.hasPrefix($0.path + "/") }) ||
                path.hasSuffix("/.git") || path.contains("/.git/worktrees/")
            }
            let paths = needsDiscovery ? Git.discover(directory) : Array(previous.keys)
            if Task.isCancelled { return }
            let sharedRefsChanged = pathsChanged.contains {
                $0.contains("/.git/refs/") || $0.hasSuffix("/.git/packed-refs") || $0.contains("/.git/worktrees/")
            }
            let dirty = paths.filter { url in
                !automatic || previous[url] == nil || pathsChanged.isEmpty || sharedRefsChanged ||
                    pathsChanged.contains { $0 == url.path || $0.hasPrefix(url.path + "/") }
            }
            let initial = paths.map { url in
                previous[url] ?? Worktree(url: url, branch: "正在读取状态…", head: nil, base: nil, ancestor: nil, changes: [], pending: true)
            }
            await self?.showWorktrees(initial, token: token)
            // Do not capture a mutable weak reference in the concurrently callable closure.
            await WorktreeScan.inspect(dirty, priority: priority, bases: bases) { [weak self] batch in
                await self?.applyWorktrees(batch, token: token)
            }
            await self?.finishScan(token: token)
        }
    }

    private func showWorktrees(_ initial: [Worktree], token: UUID) {
        guard refreshToken == token else { return }
        let selectedWasRemoved = repoID != nil && !initial.contains { $0.id == repoID }
        repos = sorted(initial)
        if selectedWasRemoved, !editing {
            repoID = nil
            fileID = nil
            loadFile()
        }
    }

    private func applyWorktrees(_ batch: [Worktree], token: UUID) {
        guard refreshToken == token else { return }
        let updated = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })
        repos = repos.map { updated[$0.id] ?? $0 }
        guard !editing else { return }
        if repoID == nil, let first = repos.first(where: { !$0.changes.isEmpty }) {
            repoID = first.id
        }
        if let repoID, updated[repoID] != nil { updateSelectedFile() }
    }

    private func finishScan(token: UUID) {
        guard refreshToken == token else { return }
        repos = sorted(repos)
        if repoID == nil, !editing { repoID = repos.first?.id; updateSelectedFile() }
        scanning = false
        scanTask = nil
        if manualRefreshQueued {
            manualRefreshQueued = false
            refreshAgain = false
            refresh()
        } else if refreshAgain {
            refreshAgain = false
            scheduleRefresh()
        }
    }

    private func updateSelectedFile() {
        let oldFile = fileID
        let oldLayer = layer
        if file == nil { fileID = repo?.changes.first?.id }
        if file?.layers.contains(layer) != true { layer = file?.layers.first ?? .work }
        loadFile(preserveScroll: oldFile == fileID && oldLayer == layer)
    }

    private func sorted(_ worktrees: [Worktree]) -> [Worktree] {
        worktrees.sorted {
            let left = (!$0.changes.isEmpty || $0.issue != nil)
            let right = (!$1.changes.isEmpty || $1.issue != nil)
            return left == right ? $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending : left && !right
        }
    }

    func chooseRepo(_ id: URL) {
        guard id != repoID, !busy, leaveEditor() else { return }
        repoID = id
        fileID = repo?.changes.first?.id
        layer = file?.layers.first ?? .work
        loadFile()
    }

    func chooseFile(_ file: Change) {
        guard file.id != fileID, !busy, leaveEditor() else { return }
        fileID = file.id
        layer = file.layers.first ?? .work
        fullVersion = .right
        loadFile()
    }

    func chooseLayer(_ next: Layer) {
        guard next != layer, !busy, leaveEditor() else { return }
        layer = next
        fullVersion = .right
        loadFile()
    }

    func setIgnoresWhitespace(_ enabled: Bool) {
        guard enabled != ignoresWhitespace, !editing, !busy else { return }
        ignoresWhitespace = enabled
        environment.set(enabled, forKey: "ignoresWhitespace")
        loadFile(preserveScroll: true)
    }

    func loadFile(preserveScroll: Bool = false) {
        fileLoadTask?.cancel()
        let token = UUID()
        loadToken = token
        if !preserveScroll || file == nil { comparison = nil; layoutRevision = UUID() }
        fileIssue = nil
        guard let file, let repo else { loading = false; return }
        loading = true
        let selectedLayer = layer
        let ignoresWhitespace = self.ignoresWhitespace
        let previous = preserveScroll ? comparison : nil
        let worker = Task.detached(priority: .userInitiated) {
            Result {
                try Git.compare(file, layer: selectedLayer, repo: repo,
                                ignoresWhitespace: ignoresWhitespace, previous: previous)
            }
        }
        fileLoadTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, token == self.loadToken, !self.editing else { return }
            self.loading = false
            switch result {
            case .success(let value): self.comparison = value
            case .failure(let error):
                self.comparison = nil
                self.fileIssue = error.localizedDescription
            }
        }
    }

    func beginEditing() {
        guard !busy, !loading, canEdit, let text = comparison?.disk.text else { return }
        draft = text
        mode = .full
        fullVersion = .disk
        editing = true
    }

    func leaveEditor() -> Bool {
        if hasDraft {
            let panel = NSAlert()
            panel.messageText = "放弃未保存的编辑？"
            panel.informativeText = "可以取消并回到文件，继续编辑或保存。"
            panel.addButton(withTitle: "继续编辑")
            panel.addButton(withTitle: "放弃编辑")
            if panel.runModal() != .alertSecondButtonReturn { return false }
        }
        editing = false
        return true
    }

    func changeMode(_ next: Mode) {
        guard next != mode, leaveEditor() else { return }
        mode = next
    }

    func save() {
        guard editing, !busy, let file, let repo, let old = comparison?.disk else { return }
        let next = Data(draft.utf8)
        do {
            let url = try Git.diskURL(file.path, in: repo.url)
            let current = try Git.disk(file.path, in: repo.url)
            guard current.present, current.bytes == old.bytes, current.label == old.label else {
                throw GitError.message("磁盘上的文件已被修改或删除。你的编辑仍在，请先复制草稿，再重新打开磁盘版本合并。")
            }
            if next != old.bytes { try next.write(to: url, options: .atomic) }
            editing = false
            notice = "已保存 "+file.path
            loadFile()
            refresh()
        } catch { issue = error.localizedDescription }
    }

    func stage(_ undo: Bool) {
        guard let file, let repo, file.group == .work, leaveEditor() else { return }
        let paths = [file.path] + (file.oldPath.map { [$0] } ?? [])
        let args: [String]
        if undo {
            args = repo.head == nil ? ["rm", "--cached", "--force", "--"] + paths : ["restore", "--staged", "--"] + paths
        } else {
            args = ["add", "-A", "--"] + paths
        }
        mutate(repo, message: undo ? "已取消暂存" : "已暂存") { try Git.run(args, at: repo.url, writing: true) }
    }

    func fetch() {
        guard let repo else { return }
        mutate(repo, message: "已更新远端引用") { try Git.run(["fetch"], at: repo.url, writing: true) }
    }

    func commit(_ message: String, expected: Data, head: String?) {
        guard let repo, leaveEditor() else { return }
        mutate(repo, message: "已提交到 "+repo.branch) {
            let now = try Git.run(["rev-parse", "--verify", "HEAD"], at: repo.url, allow: [0, 128])
            let currentHead = now.code == 0 ? now.text.trimmingCharacters(in: .newlines) : nil
            guard currentHead == head, try Git.indexState(at: repo.url) == expected else {
                throw GitError.message("暂存区或 HEAD 已改变，请重新检查提交内容。")
            }
            return try Git.run(["commit", "-m", message], at: repo.url, writing: true)
        }
    }

    private func mutate(_ repo: Worktree, message: String, run: @escaping @Sendable () throws -> Git.Result) {
        guard !busy else { return }
        busy = true
        issue = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try run() } }.value
            busy = false
            switch result {
            case .success: notice = message
            case .failure(let error): issue = error.localizedDescription
            }
            refresh()
        }
    }

    func relative(_ url: URL) -> String {
        guard let directory else { return url.lastPathComponent }
        if url == directory { return url.lastPathComponent }
        return String(url.path.dropFirst(directory.path.count+1))
    }
}

private final class DirectoryWatch {
    var stream: FSEventStreamRef?
    let change: ([String]) -> Void

    init?(url: URL, change: @escaping ([String]) -> Void) {
        self.change = change
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let strings = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            let relevant = (0..<count).compactMap { index -> String? in
                guard let path = strings[index] as? String,
                      Set(path.split(separator: "/").map(String.init)).isDisjoint(with: Git.ignoreDirectories.subtracting([".git"])) else { return nil }
                return path
            }
            if !relevant.isEmpty { Unmanaged<DirectoryWatch>.fromOpaque(info).takeUnretainedValue().change(relevant) }
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.35, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        if !FSEventStreamStart(stream) { return nil }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
