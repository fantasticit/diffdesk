import AppKit
import SwiftUI

// Use the property wrapper on Command Line Tools, where the newer State macro plugin isn't shipped.
typealias DeskState<Value> = State<Value>

@main
struct DiffPlusApp: App {
    @StateObject private var workspace = Workspace()

    var body: some Scene {
        Window("diff+", id: "workspace") {
            DeskView(model: workspace)
                .frame(minWidth: 930, minHeight: 510)
                .task { workspace.start() }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1300, height: 785)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("打开工作区…") { workspace.chooseDirectory() }
                    .keyboardShortcut("o")
                    .disabled(workspace.busy)
                Menu("最近的工作区") {
                    ForEach(workspace.recentWorkspaces, id: \.self) { url in
                        Button(url.path) { workspace.openRecent(url) }
                            .disabled(url == workspace.directory)
                    }
                }
                .disabled(workspace.recentWorkspaces.isEmpty || workspace.busy)
            }
            CommandGroup(after: .saveItem) {
                Button("保存文件") { workspace.save() }
                    .keyboardShortcut("s")
                    .disabled(!workspace.hasDraft || workspace.busy)
                Button("刷新工作区") { workspace.refresh() }
                    .keyboardShortcut("r")
                    .disabled(workspace.directory == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("筛选变更文件") {
                    NotificationCenter.default.post(name: .showChangeSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace.repo == nil)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("在文件中搜索…") { FileSearchCommand.open.send() }
                    .keyboardShortcut("f")
                    .disabled(!workspace.hasSearchableText)
                Button("下一个匹配") { FileSearchCommand.next.send() }
                    .keyboardShortcut("g")
                    .disabled(!workspace.hasSearchableText)
                Button("上一个匹配") { FileSearchCommand.previous.send() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!workspace.hasSearchableText)
            }
        }
    }
}

extension Notification.Name {
    static let showChangeSearch = Self("diffplus.showChangeSearch")
    static let fileSearch = Self("diffplus.fileSearch")
}

private enum FileSearchCommand {
    case open, next, previous

    func send() {
        NotificationCenter.default.post(name: .fileSearch, object: self)
    }
}

struct DeskView: View {
    @ObservedObject var model: Workspace
    @DeskState private var baseSheet = false
    @DeskState private var baseText = ""
    @DeskState private var commitSheet = false
    @DeskState private var commitText = ""
    @DeskState private var commitPaths: [String] = []
    @DeskState private var commitState = Data()
    @DeskState private var commitHead: String?
    @DeskState private var preparingCommit = false
    @DeskState private var repoFilter = ""
    @DeskState private var directoryFilter = ""
    @DeskState private var onlyChanged = false
    @DeskState private var expandedDirectories: Set<String> = []
    @DeskState private var collapsedSearchDirectories: Set<String> = []
    @DeskState private var changeScope: ChangeScope = .all
    @DeskState private var selection = NavigationSplitViewVisibility.all
    @DeskState private var showOutline = false
    @DeskState private var outlineSide = SourceSide.after
    @DeskState private var viewport = TextViewport()
    @DeskState private var textJump: TextJump?
    @DeskState private var showFileSearch = false
    @DeskState private var fileSearchQuery = ""
    @DeskState private var fileSearchSide = SourceSide.after
    @DeskState private var fileSearchResult: FileSearchResult?
    @DeskState private var fileSearchSelection = 0
    @DeskState private var fileSearchRevealID: UUID?
    @FocusState private var search: SearchField?
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    private enum SearchField: Hashable { case repositories, files, code }
    private enum ChangeScope: String, CaseIterable {
        case all = "全部", work = "未提交", branch = "未合入"

        var group: Group? {
            switch self {
            case .all: nil
            case .work: .work
            case .branch: .branch
            }
        }
    }

    var body: some View {
        let request = fileSearchRequest
        NavigationSplitView(columnVisibility: $selection) {
            repositories
                .navigationSplitViewColumnWidth(min: 172, ideal: 222, max: 360)
        } content: {
            changesPane
                .navigationSplitViewColumnWidth(min: 210, ideal: 254, max: 390)
        } detail: {
            VStack(spacing: 0) {
                review
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let message = model.issue { issueBanner(message) }
                Divider()
                statusBar
            }
            .background(DeskStyle.canvas)
            .navigationTitle(model.directory?.lastPathComponent ?? "diff+")
            .toolbar { workspaceToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(DeskStyle.accent)
        .onChange(of: model.directory) { _, _ in repoFilter = "" }
        .onChange(of: model.repoID) { _, _ in
            changeScope = .all
            directoryFilter = ""
            expandedDirectories = parentFolders(of: model.file?.path)
            collapsedSearchDirectories = []
        }
        .onChange(of: model.fileID, initial: true) { _, _ in
            expandedDirectories.formUnion(parentFolders(of: model.file?.path))
        }
        .onReceive(NotificationCenter.default.publisher(for: .showChangeSearch)) { _ in
            if selection == .detailOnly { selection = .doubleColumn }
            search = .files
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileSearch)) { notification in
            switch notification.object as? FileSearchCommand {
            case .open: openFileSearch()
            case .next: stepFileSearch(1)
            case .previous: stepFileSearch(-1)
            case nil: break
            }
        }
        .task(id: request) { await updateFileSearch(request) }
        .onChange(of: model.layoutRevision) { _, _ in textJump = nil }
        .onChange(of: model.fullVersion) { _, _ in textJump = nil }
        .onChange(of: outlineSide) { _, _ in textJump = nil }
        .sheet(isPresented: $baseSheet) { baseEditor }
        .sheet(isPresented: $commitSheet) { commitEditor }
    }

    private var searchesSingleDiffSide: Bool {
        model.mode != .full && !(model.mode == .unified && model.comparison?.rows.isEmpty == false)
    }

    private var hasSearchableReview: Bool {
        model.hasSearchableText && (changeScope.group == nil || model.file?.group == changeScope.group)
    }

    private var fileSearchRequest: FileSearchRequest? {
        guard showFileSearch, hasSearchableReview, !fileSearchQuery.isEmpty,
              let comparison = model.comparison else { return nil }
        if model.mode == .full {
            guard let text = model.editing ? model.draft : model.fullSnapshot?.text else { return nil }
            return FileSearchRequest(query: fileSearchQuery, surface: .full, document: .text(text))
        }
        if !searchesSingleDiffSide {
            return FileSearchRequest(query: fileSearchQuery, surface: .unified, document: .diff(comparison, .unified))
        }
        let before = comparison.left.text
        let after = comparison.right.text
        let left = before != nil && (fileSearchSide == .before || after == nil)
        guard let text = left ? before : after else { return nil }
        let surface: FileSearchSurface = left ? .before : .after
        let document: FileSearchDocument = comparison.rows.isEmpty ? .text(text) : .diff(comparison, surface)
        return FileSearchRequest(query: fileSearchQuery, surface: surface, document: document)
    }

    private var currentFileSearchResult: FileSearchResult? {
        guard let result = fileSearchResult, result.request == fileSearchRequest else { return nil }
        return result
    }

    private func openFileSearch() {
        guard hasSearchableReview else { return }
        showFileSearch = true
        search = .code
    }

    private func closeFileSearch() {
        showFileSearch = false
        if search == .code { search = nil }
    }

    private func stepFileSearch(_ delta: Int) {
        guard let count = currentFileSearchResult?.matches.count, count > 0 else { return }
        fileSearchSelection = (fileSearchSelection + delta + count) % count
        fileSearchRevealID = UUID()
    }

    private func updateFileSearch(_ request: FileSearchRequest?) async {
        guard let request else {
            fileSearchResult = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(90))
            let worker = Task.detached(priority: .userInitiated) { try request.matches() }
            let matches = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard request == fileSearchRequest else { return }
            let editingText = model.editing && search != .code
                && fileSearchResult?.request.query.utf8.elementsEqual(request.query.utf8) == true
            fileSearchSelection = editingText ? min(fileSearchSelection, max(0, matches.count - 1)) : 0
            fileSearchRevealID = editingText ? nil : UUID()
            fileSearchResult = FileSearchResult(request: request, matches: matches)
        } catch is CancellationError {
            return
        } catch {
            fileSearchResult = nil
        }
    }

    private var fileSearchMarks: (surface: FileSearchSurface, marks: FileSearchMarks)? {
        guard let result = currentFileSearchResult, result.matches.indices.contains(fileSearchSelection) else { return nil }
        return (result.request.surface,
                FileSearchMarks(result: result, selection: fileSearchSelection, revealID: fileSearchRevealID))
    }

    private var fileSearchBar: some View {
        let result = currentFileSearchResult
        let hasMatches = result?.matches.isEmpty == false
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("在文件中搜索", text: $fileSearchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($search, equals: .code)
                .onSubmit { stepFileSearch(1) }
                .onAppear { search = .code }
                .frame(minWidth: 96, maxWidth: 340)
            if searchesSingleDiffSide, model.comparison?.left.text != nil, model.comparison?.right.text != nil {
                Picker("搜索范围", selection: $fileSearchSide) {
                    ForEach(SourceSide.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Spacer(minLength: 0)
            if !model.hasSearchableText {
                Text(model.loading ? "正在加载文件…" : "此版本无可搜索文本")
            } else if !fileSearchQuery.isEmpty {
                if let result {
                    if hasMatches {
                        Text("\((fileSearchSelection + 1).formatted()) / \(result.matches.count.formatted())")
                            .accessibilityLabel("第 \(fileSearchSelection + 1) 个匹配，共 \(result.matches.count) 个")
                    } else {
                        Text("无匹配")
                    }
                } else {
                    ProgressView().controlSize(.mini).accessibilityLabel("正在搜索")
                }
            }
            Button("上一个匹配", systemImage: "chevron.up") { stepFileSearch(-1) }
                .help("上一个匹配（⇧⌘G）").disabled(!hasMatches)
            Button("下一个匹配", systemImage: "chevron.down") { stepFileSearch(1) }
                .help("下一个匹配（⌘G）").disabled(!hasMatches)
            Button("关闭文件内搜索", systemImage: "xmark", action: closeFileSearch)
                .help("关闭搜索（Esc）")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 13)
        .frame(height: 37)
        .background(DeskStyle.panel)
        .onExitCommand(perform: closeFileSearch)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文件内搜索")
    }

    @ToolbarContentBuilder private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: model.chooseDirectory) { Label("打开工作区", systemImage: "folder") }
                .help("打开工作区（⌘O）")
                .disabled(model.busy)
            Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                .help("刷新工作区（⌘R）")
                .disabled(model.directory == nil || model.scanning || model.busy)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("在 Finder 中显示工作树") {
                    if let repo = model.repo { NSWorkspace.shared.activateFileViewerSelecting([repo.url]) }
                }
                Button("设置对比基准…") {
                    if let repo = model.repo { baseText = model.priorBase(for: repo.url) ?? "" }
                    baseSheet = true
                }
                Button("更新远端引用（Fetch）") { model.fetch() }
                Divider()
                Button("提交暂存区…", action: prepareCommit).disabled(preparingCommit)
            } label: {
                Label("仓库操作", systemImage: "ellipsis")
            }
            .help("仓库操作")
            .disabled(model.repo == nil || model.busy || model.repo?.issue != nil)
        }
    }

    private var repositories: some View {
        let query = SearchQuery(repoFilter)
        let candidates = model.repos.filter { !onlyChanged || !$0.changes.isEmpty || $0.issue != nil || $0.pending }
        let visible = query.ranked(candidates) { query.score($0, relativePath: model.relative($0.url)) }
        let selected = Binding<URL?>(
            get: { model.repoID },
            set: { if let id = $0 { model.chooseRepo(id) } }
        )
        return VStack(spacing: 0) {
            searchField("筛选工作树", text: $repoFilter, field: .repositories) {
                if let first = visible.first { model.chooseRepo(first.id) }
            }
            List(selection: selected) {
                Section {
                    ForEach(visible) { repo in
                        repoLabel(repo, showPath: !query.isEmpty)
                            .tag(repo.id)
                            .help(model.relative(repo.url))
                    }
                } header: {
                    HStack {
                        Text("工作树")
                        Spacer()
                        Text(visible.count.formatted()).monospacedDigit()
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if visible.isEmpty {
                    if model.scanning {
                        ProgressView("正在扫描…").controlSize(.small)
                    } else {
                        Text(model.directory == nil ? "打开工作区后显示工作树" :
                                (query.isEmpty && !onlyChanged ? "未找到 Git 工作树" : "没有匹配的工作树"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
            Toggle("只看有变更", isOn: $onlyChanged)
                .toggleStyle(.checkbox)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .disabled(model.directory == nil)
        }
    }

    private func repoLabel(_ repo: Worktree, showPath: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: repo.issue == nil ? "square.stack.3d.up" : "exclamationmark.triangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(repo.issue == nil ? DeskStyle.accent : .orange)
                .frame(width: 19, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(repo.url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(repo.branch)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if showPath {
                    Text(model.relative(repo.url))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if repo.pending {
                ProgressView().controlSize(.mini).accessibilityLabel("读取状态中")
            } else if !repo.changes.isEmpty {
                Text(repo.changes.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(repo.changes.count) 项变更")
            }
        }
        .padding(.vertical, 4)
    }

    private func searchField(
        _ title: String, text: Binding<String>, field: SearchField, onSubmit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .focused($search, equals: field)
                .onSubmit(onSubmit)
                .onExitCommand { text.wrappedValue = "" }
            if !text.wrappedValue.isEmpty {
                Button("清除筛选", systemImage: "xmark.circle.fill") {
                    text.wrappedValue = ""
                    search = field
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
        .overlay {
            if search == field {
                RoundedRectangle(cornerRadius: 7).strokeBorder(DeskStyle.accent)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var changesPane: some View {
        let changes = model.repo?.changes ?? []
        let filtered = changes.filter { changeScope.group == nil || $0.group == changeScope.group }
        let query = SearchQuery(directoryFilter)
        let rows = ChangeFileTree(changes: filtered, query: query).rows { isExpanded($0, query: query) }
        let selected = Binding<String?>(
            get: { model.fileID },
            set: { next in
                if let file = filtered.first(where: { $0.id == next }) { model.chooseFile(file) }
            }
        )
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("变更").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if model.repo?.pending == false {
                    Text("\(Set(filtered.map(\.path)).count) 个文件")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            searchField("筛选目录或文件", text: $directoryFilter, field: .files) {
                for row in rows {
                    if case let .file(file) = row.item { model.chooseFile(file); break }
                }
            }
            .onChange(of: directoryFilter) { _, _ in collapsedSearchDirectories = [] }

            Picker("变更范围", selection: Binding(get: { changeScope }, set: selectScope)) {
                ForEach(ChangeScope.allCases, id: \.self) { scope in
                    let count = changes.lazy.filter { scope.group == nil || $0.group == scope.group }.count
                    let indicator = model.repo?.pending == true ? "…" :
                        scope == .branch && model.repo?.ancestor == nil ? "—" : count.formatted()
                    Text("\(scope.rawValue) \(indicator)").tag(scope)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(model.repo == nil)
            .padding(.horizontal, 12)
            .padding(.bottom, 9)

            Divider()
            if rows.isEmpty {
                listEmpty(query: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selected) {
                    ForEach(rows) { entry in treeRow(entry, query: query) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
            if let repo = model.repo {
                Divider()
                Label(repo.base.map { "基准  " + $0 } ?? "没有可用基准", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13).padding(.vertical, 8)
            }
        }
        .background(DeskStyle.panel)
    }

    @ViewBuilder private func listEmpty(query: SearchQuery) -> some View {
        if model.repo?.pending == true {
            ProgressView("正在读取状态…").controlSize(.small)
        } else {
            let message = model.repo == nil ? "选择工作树" :
                !query.isEmpty ? "没有匹配的文件" :
                changeScope == .branch && model.repo?.ancestor == nil ? "没有可用的对比基准" : "没有变更文件"
            Text(message).font(.callout).foregroundStyle(.secondary).padding()
        }
    }

    private func selectScope(_ scope: ChangeScope) {
        guard scope != changeScope else { return }
        if let group = scope.group, model.file?.group != group {
            if let next = model.repo?.changes.first(where: { $0.group == group }) {
                model.chooseFile(next)
                guard model.fileID == next.id else { return }
            } else if model.editing, !model.leaveEditor() {
                return
            }
        }
        changeScope = scope
    }

    private func parentFolders(of file: String?) -> Set<String> {
        guard let file else { return [] }
        var result: Set<String> = []
        var parent = (file as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            result.insert(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        return result
    }

    private func isExpanded(_ path: String, query: SearchQuery) -> Bool {
        query.isEmpty ? expandedDirectories.contains(path) : !collapsedSearchDirectories.contains(path)
    }

    @ViewBuilder private func treeRow(_ entry: ChangeFileTree.Entry, query: SearchQuery) -> some View {
        let indent = CGFloat(min(entry.depth, 8)) * 10
        switch entry.item {
        case .folder(let path, let count):
            let expanded = isExpanded(path, query: query)
            Button {
                withAnimation(reducedMotion ? nil : .easeOut(duration: 0.14)) {
                    if query.isEmpty {
                        if expanded { expandedDirectories.remove(path) } else { expandedDirectories.insert(path) }
                    } else {
                        if expanded { collapsedSearchDirectories.insert(path) } else { collapsedSearchDirectories.remove(path) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Image(systemName: "folder")
                        .foregroundStyle(DeskStyle.accent)
                        .accessibilityHidden(true)
                    Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 3)
                    Text(count.formatted()).monospacedDigit().foregroundStyle(.secondary).font(.caption)
                }
                .padding(.leading, indent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(path)
            .accessibilityValue(expanded ? "已展开" : "已折叠")
        case .file(let file):
            let kind = PreviewKind(path: file.path)
            HStack(spacing: 7) {
                Image(systemName: kind.symbol).foregroundStyle(kind.tint)
                    .frame(width: 17).accessibilityHidden(true)
                Text((file.path as NSString).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Image(systemName: file.group == .work ? "square.and.pencil" : "arrow.triangle.branch")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .accessibilityLabel(file.group.rawValue)
                Text(file.status.replacingOccurrences(of: ".", with: ""))
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(file.status.contains("D") ? DeskStyle.removed : file.status.contains("A") || file.status == "?" ? DeskStyle.added : .secondary)
            }
            .padding(.leading, indent + 14)
            .contentShape(Rectangle())
            .tag(file.id)
            .help(file.group.rawValue + " · " + (file.oldPath.map { $0 + " → " + file.path } ?? file.path))
            .contextMenu {
                Button("复制相对路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
        }
    }

    @ViewBuilder private var review: some View {
        if model.directory == nil {
            ContentUnavailableView {
                Label("打开工作区", systemImage: "folder.badge.gearshape")
            } description: {
                Text("选择 Git 工作树或包含多个工作树的文件夹。")
            } actions: {
                Button("打开文件夹…", action: model.chooseDirectory)
                    .buttonStyle(.borderedProminent)
            }
        } else if let issue = model.repo?.issue {
            ContentUnavailableView("无法读取工作树", systemImage: "exclamationmark.triangle", description: Text(issue))
        } else if let file = model.file, changeScope.group == nil || file.group == changeScope.group {
            VStack(spacing: 0) {
                reviewHeader(file)
                Divider()
                if showFileSearch {
                    fileSearchBar
                    Divider()
                }
                if let comparison = model.comparison {
                    documentReview(file, comparison: comparison)
                } else if let issue = model.fileIssue {
                    ContentUnavailableView {
                        Label("无法读取文件", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(issue).textSelection(.enabled)
                    } actions: {
                        Button("重试") { model.loadFile() }
                    }
                } else {
                    ProgressView("加载文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if model.repo?.pending == true || model.repo == nil && model.scanning {
            ProgressView("正在读取工作树…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(model.repo == nil ? "选择工作树" : "选择变更文件",
                                   systemImage: "rectangle.split.2x1")
        }
    }

    private func source(_ file: Change, comparison: Comparison) -> OutlineSource? {
        if model.mode == .full {
            let text = model.editing ? model.draft : model.fullSnapshot?.text
            let side: SourceSide = model.fullVersion == .left ? .before : .after
            return text.map { OutlineSource(path: file.path, text: $0, side: side) }
        }
        let right = comparison.right.text
        let left = comparison.left.text
        if let left, (outlineSide == .before || right == nil) {
            return OutlineSource(path: file.oldPath ?? file.path, text: left, side: .before)
        }
        return right.map { OutlineSource(path: file.path, text: $0, side: .after) }
    }

    @ViewBuilder private func documentReview(_ file: Change, comparison: Comparison) -> some View {
        if let source = source(file, comparison: comparison) {
            DocumentNavigator(source: source, comparison: model.mode == .full ? nil : comparison,
                              unified: model.mode == .unified,
                              canSwitchSide: model.mode != .full && comparison.left.text != nil && comparison.right.text != nil,
                              side: $outlineSide, showOutline: $showOutline, viewport: viewport,
                              jump: { textJump = TextJump(target: $0) }) {
                documentBody(file, comparison: comparison, side: source.side)
            }
        } else {
            documentBody(file, comparison: comparison, side: .after)
        }
    }

    @ViewBuilder private func documentBody(_ file: Change, comparison: Comparison, side: SourceSide) -> some View {
        if model.mode == .full {
            fullFile(comparison)
        } else {
            DifferenceView(comparison: comparison, path: file.path, unified: model.mode == .unified,
                           sourceSide: side, viewport: viewport, jump: textJump,
                           searchMarks: fileSearchMarks,
                           isLoading: model.loading, whitespaceDisabled: model.busy,
                           setIgnoresWhitespace: model.setIgnoresWhitespace)
                .id(model.layoutRevision)
        }
    }

    private func reviewHeader(_ file: Change) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 11) {
                let kind = PreviewKind(path: file.path)
                Image(systemName: kind.symbol).foregroundStyle(kind.tint)
                    .font(.system(size: 21, weight: .medium))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text((file.path as NSString).lastPathComponent)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                    Text(file.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                Spacer(minLength: 8)
                Picker("审阅布局", selection: Binding(get: { model.mode }, set: { mode in
                    let previous = model.mode
                    model.changeMode(mode)
                    if previous != model.mode { textJump = nil }
                })) {
                    ForEach(Workspace.Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()

                Button("在文件中搜索", systemImage: "magnifyingglass", action: openFileSearch)
                    .labelStyle(.iconOnly)
                    .controlSize(.small)
                    .help("在文件中搜索（⌘F）")
                    .disabled(!model.hasSearchableText)

                Toggle("大纲", systemImage: "list.bullet.indent", isOn: $showOutline)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .help("显示或隐藏文件大纲（⇧⌘O）")
                    .disabled(model.comparison.flatMap { source(file, comparison: $0) } == nil)
            }

            HStack(spacing: 9) {
                if file.layers.count > 1 && !model.editing {
                    Picker("Git 状态", selection: Binding(get: { model.layer }, set: model.chooseLayer)) {
                        ForEach(file.layers) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                } else {
                    Label(model.editing ? "正在编辑工作区" : model.layer.rawValue,
                          systemImage: model.editing ? "pencil" : "circle.lefthalf.filled")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if model.editing {
                    Button("取消") { if model.leaveEditor() { model.changeMode(.compare) } }
                        .disabled(model.busy)
                    Button("保存", systemImage: "checkmark", action: model.save)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasDraft || model.busy)
                } else {
                    Button("编辑", systemImage: "pencil", action: model.beginEditing)
                        .help("编辑工作区文件")
                        .disabled(!model.canEdit || model.loading || model.busy)
                    if file.group == .work {
                        if file.layers.contains(.index) {
                            Button("取消暂存") { model.stage(true) }.disabled(model.busy)
                        }
                        if file.layers.contains(where: { $0 != .index }) {
                            Button("暂存", systemImage: "plus") { model.stage(false) }
                                .disabled(model.busy)
                        }
                    }
                }
            }
            .controlSize(.small)
            .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DeskStyle.panel)
    }

    private func fullFile(_ comparison: Comparison) -> some View {
        VStack(spacing: 0) {
            if !model.editing {
                HStack {
                    Picker("文件版本", selection: $model.fullVersion) {
                        Text(comparison.left.label).tag(Workspace.FullVersion.left)
                        Text(comparison.right.label).tag(Workspace.FullVersion.right)
                        if comparison.right.label != "工作区" { Text("工作区").tag(Workspace.FullVersion.disk) }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(DeskStyle.panel)
                Divider()
            }
            if model.editing {
                NativeText(text: model.draft, editable: true, viewport: viewport, jump: textJump,
                           searchMarks: fileSearchMarks?.marks) { model.draft = $0 }
                    .id(model.layoutRevision)
            } else if let snapshot = model.fullSnapshot, let file = model.file {
                FilePreview(snapshot: snapshot, path: file.path, viewport: viewport, jump: textJump,
                            searchMarks: fileSearchMarks?.marks)
                    .id(model.fullVersion)
            }
        }
    }

    private func issueBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).textSelection(.enabled)
            Spacer()
            Button("关闭提示", systemImage: "xmark") { model.issue = nil }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(12)
        .background(.orange.opacity(0.12))
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            if model.busy || model.scanning {
                ProgressView().controlSize(.mini)
                Text(model.busy ? "正在运行 Git 操作…" : "正在扫描工作区…")
            } else {
                Text(model.notice ?? "\(model.repos.count) 个工作树").lineLimit(1)
            }
            Spacer(minLength: 8)
            if let repo = model.repo {
                Label(repo.branch, systemImage: "arrow.triangle.branch")
                    .font(.caption.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                    .help(repo.url.path)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 13)
        .frame(height: 28)
        .background(.bar)
    }

    private var baseEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("对比基准").font(.headline)
            Text("输入用于比较当前分支的本地引用。留空时自动选择。").foregroundStyle(.secondary)
            TextField("例如 origin/main", text: $baseText)
            HStack {
                Spacer()
                Button("取消") { baseSheet = false }.keyboardShortcut(.cancelAction)
                Button("应用") { model.setBase(baseText); baseSheet = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 420)
    }

    private func prepareCommit() {
        guard let repo = model.repo, !preparingCommit else { return }
        preparingCommit = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let head = try Git.run(["rev-parse", "--verify", "HEAD"], at: repo.url, allow: [0, 128])
                    let state = try Git.indexState(at: repo.url)
                    let files = try Git.stagedPaths(at: repo.url)
                    guard state == (try Git.indexState(at: repo.url)) else {
                        throw GitError.message("暂存区正在变化，请重新打开提交。")
                    }
                    return (head.code == 0 ? head.text.trimmingCharacters(in: .newlines) : nil, state, files)
                }
            }.value
            preparingCommit = false
            guard model.repoID == repo.id else { return }
            switch result {
            case .success(let (head, state, files)):
                guard !files.isEmpty else { model.notice = "暂存区没有文件"; return }
                commitHead = head
                commitState = state
                commitPaths = files
                commitText = ""
                commitSheet = true
            case .failure(let error): model.issue = error.localizedDescription
            }
        }
    }

    private var commitEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提交到 "+(model.repo?.branch ?? "")).font(.headline)
            TextField("提交说明", text: $commitText)
            Text("本次提交包含 \(commitPaths.count) 个暂存文件").font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(commitPaths, id: \.self) { Text($0).font(.callout.monospaced()) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
            HStack {
                Spacer()
                Button("取消") { commitSheet = false }.keyboardShortcut(.cancelAction)
                Button("提交") {
                    commitSheet = false
                    model.commit(commitText.trimmingCharacters(in: .whitespacesAndNewlines), expected: commitState, head: commitHead)
                }.keyboardShortcut(.defaultAction)
                 .disabled(commitText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 450)
    }
}
