import AppKit
import SwiftUI

@main
struct ChangeDeskApp: App {
    @StateObject private var workspace = Workspace()

    var body: some Scene {
        Window("Diffdesk", id: "workspace") {
            DeskView(model: workspace)
                .frame(minWidth: 850, minHeight: 490)
                .ignoresSafeArea(.container, edges: .top)
                .task { workspace.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1260, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开工作区…") { workspace.chooseDirectory() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("保存文件") { workspace.save() }
                    .keyboardShortcut("s")
                    .disabled(!workspace.editing)
                Button("刷新工作区") { workspace.refresh() }
                    .keyboardShortcut("r")
                    .disabled(workspace.directory == nil)
            }
        }
    }
}

struct DeskView: View {
    @ObservedObject var model: Workspace
    @State private var baseSheet = false
    @State private var baseText = ""
    @State private var commitSheet = false
    @State private var commitText = ""
    @State private var commitPaths: [String] = []
    @State private var commitState = Data()
    @State private var commitHead: String?
    @State private var preparingCommit = false
    @State private var repoFilter = ""
    @State private var directoryFilter = ""
    @State private var expandedDirectories: Set<String> = []
    @State private var collapsedSearchDirectories: Set<String> = []
    @State private var changeScope: ChangeScope = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum ChangeScope: String, CaseIterable {
        case all = "全部", work = "未提交", branch = "未合入"
    }

    private var interaction: Animation? { reduceMotion ? nil : .easeOut(duration: 0.16) }
    @FocusState private var focusedSearch: SearchField?

    private enum SearchField: Hashable { case worktrees, changes }
    @State private var hoveredRow: String?
    @State private var sidebarVisible = true
    private static let logo = NSImage(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Diffdesk.icns"))

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.directory == nil {
                empty("选择工作区", icon: "folder", detail: "打开包含多个 Git 仓库的父目录。") {
                    Button("打开文件夹…") { model.chooseDirectory() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: 0) {
                    if sidebarVisible {
                        repositories.frame(width: 190)
                        DeskStyle.border.frame(width: 1)
                    }
                    files.frame(width: 244)
                    DeskStyle.border.frame(width: 1)
                    review.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let issue = model.issue {
                HStack(alignment: .top) {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.primary).textSelection(.enabled)
                    Spacer()
                    Button("关闭", systemImage: "xmark") { model.issue = nil }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }
                .font(.callout).padding(10)
                .background(Color.orange.opacity(0.12))
            }
            Divider()
            footer
        }
        .background(DeskStyle.content)
        .tint(DeskStyle.accent)
        .onChange(of: model.directory) { _, _ in
            repoFilter = ""
        }
        .onChange(of: model.repoID) { _, _ in
            changeScope = .all
            directoryFilter = ""
            expandedDirectories = parentFolders(of: model.file?.path)
            collapsedSearchDirectories = []
        }
        .onChange(of: model.fileID, initial: true) { _, next in
            if next != nil {
                expandedDirectories.formUnion(parentFolders(of: model.file?.path))
            }
        }
        .sheet(isPresented: $baseSheet) { baseEditor }
        .sheet(isPresented: $commitSheet) { commitEditor }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            if let logo = Self.logo {
                Image(nsImage: logo).resizable().frame(width: 30, height: 30).accessibilityHidden(true)
            }
            Text("Diffdesk").font(.system(size: 16, weight: .semibold)).foregroundStyle(DeskStyle.ink)
            Rectangle().fill(DeskStyle.border).frame(width: 1, height: 22).padding(.horizontal, 4)
            Button { model.chooseDirectory() } label: {
                Label(model.directory?.lastPathComponent ?? "打开工作区", systemImage: "folder")
            }
            .buttonStyle(DeskButton())
            .help(model.directory?.path ?? "打开工作区（⌘O）")
            .accessibilityLabel("打开工作区")
            .disabled(model.busy)
            WindowDragArea().frame(minWidth: 16, maxWidth: .infinity)
            if model.directory != nil {
                Button { sidebarVisible.toggle() } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(DeskButton())
                .help(sidebarVisible ? "隐藏工作树" : "显示工作树")
                .accessibilityLabel(sidebarVisible ? "隐藏工作树" : "显示工作树")
            }
            if model.scanning || model.busy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(model.busy ? "正在运行 Git 操作" : "正在扫描工作区")
            }
            Button { model.refresh() } label: {
                Label("刷新工作区", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            }.buttonStyle(DeskButton()).help("刷新（⌘R）").disabled(model.directory == nil || model.scanning || model.busy)
            Menu {
                Button("设置对比基准…", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                    if let repo = model.repo { baseText = model.priorBase(for: repo.url) ?? "" }
                    baseSheet = true
                }
                Button("更新远端引用（Fetch）", systemImage: "arrow.down.circle") { model.fetch() }
                Divider()
                Button("提交暂存区…", systemImage: "checkmark.circle") { prepareCommit() }.disabled(preparingCommit)
            } label: { Label("仓库操作", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.repo == nil || model.busy || model.repo?.issue != nil)
        }
        .padding(.leading, 82)
        .padding(.trailing, 13)
        .frame(height: 42)
        .background(DeskStyle.panel)
    }

    private var repositories: some View {
        let query = SearchQuery(repoFilter)
        let repos = query.ranked(model.repos) { query.score($0, relativePath: model.relative($0.url)) }
        return VStack(spacing: 0) {
            sectionHeader("工作树", icon: "square.stack.3d.up", count: repos.count)
            searchField("搜索工作树、分支或路径", text: $repoFilter, field: .worktrees) {
                if let first = repos.first { selectWorktree(first.id) }
            }
            if repos.isEmpty {
                Text(model.scanning ? "扫描目录中…" : query.isEmpty ? "未找到 Git 工作树" : "没有匹配的工作树")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(repos) { repo in
                            let work = repo.pending ? "…" : String(repo.changes.lazy.filter { $0.group == .work }.count)
                            let branch = repo.pending ? "…" : repo.ancestor == nil ? "—" : String(repo.changes.lazy.filter { $0.group == .branch }.count)
                            row(key: repo.url.path, selected: repo.id == model.repoID, action: { selectWorktree(repo.id) }) {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: "shippingbox").font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(repo.id == model.repoID ? DeskStyle.accent : .secondary)
                                        .frame(width: 16, height: 17)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(repo.url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        Text(repo.branch).font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
                                        if !query.isEmpty {
                                            Text(model.relative(repo.url)).font(.system(size: 10))
                                                .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                                        }
                                        HStack(spacing: 12) {
                                            countMark(work, icon: "square.and.pencil", label: "未提交")
                                            countMark(branch, icon: "arrow.triangle.branch", label: "已提交未合入")
                                        }.padding(.top, 2)
                                    }
                                }
                            }
                            .overlay(alignment: .leading) {
                                Capsule().fill(DeskStyle.accent).frame(width: 2, height: 24)
                                    .opacity(repo.id == model.repoID ? 1 : 0)
                                    .animation(interaction, value: repo.id == model.repoID)
                                    .allowsHitTesting(false)
                            }
                            .help(model.relative(repo.url))
                        }
                    }.padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(DeskStyle.panel)
    }

    private func countMark(_ count: String, icon: String, label: String) -> some View {
        Label(count, systemImage: icon)
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .help(label).accessibilityLabel(label+" "+count)
    }

    private func selectWorktree(_ id: URL) {
        model.chooseRepo(id)
    }

    private func searchField(_ prompt: String, text: Binding<String>, field: SearchField, onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: text)
                .textFieldStyle(.plain).font(.system(size: 12))
                .accessibilityLabel(prompt)
                .focused($focusedSearch, equals: field)
                .onSubmit(onSubmit)
                .onExitCommand { if !text.wrappedValue.isEmpty { text.wrappedValue = "" } }
            if !text.wrappedValue.isEmpty {
                Button("清除筛选", systemImage: "xmark.circle.fill") {
                    text.wrappedValue = ""
                    focusedSearch = field
                }
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9).frame(height: 29)
        .background(DeskStyle.content, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focusedSearch == field ? DeskStyle.accent : DeskStyle.border)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 10).padding(.bottom, 9)
    }

    private var files: some View {
        let changes = model.repo?.changes ?? []
        let working = changes.filter { $0.group == .work }
        let committed = changes.filter { $0.group == .branch }
        let filtered = changeScope == .all ? changes : changeScope == .work ? working : committed
        return VStack(spacing: 0) {
            HStack {
                Text("变更").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.repo?.pending != true {
                    Text("\(Set(changes.map(\.path)).count) 个文件").monospacedDigit()
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            directoryBrowser(filtered, counts: [changes.count, working.count, committed.count])
            Spacer(minLength: 0)
            if let repo = model.repo {
                Divider()
                Label(repo.base.map { "相对 "+$0+" · 本地引用" } ?? "对比基准未设置",
                      systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 7)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DeskStyle.sidebar)
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

    private func directoryBrowser(_ changes: [Change], counts: [Int]) -> some View {
        let query = SearchQuery(directoryFilter)
        let rows = ChangeFileTree(changes: changes, query: query).rows { isExpanded($0, query: query) }

        return VStack(spacing: 0) {
            searchField("搜索目录或文件", text: $directoryFilter, field: .changes) {
                for entry in rows {
                    if case .file(let file) = entry.item {
                        model.chooseFile(file)
                        break
                    }
                }
            }
            .onChange(of: directoryFilter) { _, _ in collapsedSearchDirectories = [] }

            HStack(spacing: 3) {
                ForEach(Array(ChangeScope.allCases.enumerated()), id: \.element) { index, scope in
                    let count = counts[index]
                    let label = model.repo?.pending == true ? "…" : scope == .branch && model.repo?.ancestor == nil ? "—" : String(count)
                    Button {
                        guard changeScope != scope else { return }
                        withAnimation(interaction) { changeScope = scope }
                        if scope != .all, let group = model.file?.group,
                           group != (scope == .work ? .work : .branch),
                           let next = model.repo?.changes.first(where: {
                               $0.group == (scope == .work ? .work : .branch)
                           }) {
                            model.chooseFile(next)
                        }
                    } label: {
                        Text(scope.rawValue + " " + label)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .frame(maxWidth: .infinity).frame(height: 25)
                            .background(changeScope == scope ? DeskStyle.selected : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(changeScope == scope ? .isSelected : [])
                }
            }.padding(.horizontal, 9).padding(.bottom, 8)

            if rows.isEmpty {
                if model.repo?.pending == true {
                    secondary("正在读取状态…")
                } else if model.repo == nil {
                    secondary("选择工作树")
                } else {
                    secondary(changeScope == .branch && model.repo?.ancestor == nil
                              ? "没有可用的对比基准" : query.isEmpty ? "没有变更文件" : "没有匹配结果")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(rows) { entry in
                            treeRow(entry, query: query)
                                .transition(reduceMotion ? .identity : .opacity)
                        }
                    }.padding(.horizontal, 6).padding(.bottom, 5)
                }
            }
        }
    }

    private func isExpanded(_ path: String, query: SearchQuery) -> Bool {
        query.isEmpty ? expandedDirectories.contains(path) : !collapsedSearchDirectories.contains(path)
    }

    @ViewBuilder private func treeRow(_ entry: ChangeFileTree.Entry, query: SearchQuery) -> some View {
        let indent = CGFloat(min(entry.depth, 8)) * 12
        switch entry.item {
        case .folder(let path, let count):
            let expanded = isExpanded(path, query: query)
            row(key: entry.id, selected: false, action: {
                withAnimation(interaction) {
                    if query.isEmpty {
                        if expanded { expandedDirectories.remove(path) } else { expandedDirectories.insert(path) }
                    } else {
                        if expanded { collapsedSearchDirectories.insert(path) } else { collapsedSearchDirectories.remove(path) }
                    }
                }
            }) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.system(size: 9, weight: .semibold)).frame(width: 9)
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    Image(systemName: expanded ? "folder.fill" : "folder")
                        .foregroundStyle(DeskStyle.accent).accessibilityHidden(true)
                    Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    Text(String(count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.leading, indent)
            }
            .help(path)
            .accessibilityValue(expanded ? "已展开" : "已折叠")
        case .file(let file):
            let kind = PreviewKind(path: file.path)
            row(key: entry.id, selected: model.fileID == file.id, action: { model.chooseFile(file) }) {
                HStack(spacing: 7) {
                    Image(systemName: kind.symbol).foregroundStyle(kind.tint)
                        .frame(width: 16).accessibilityHidden(true)
                    Text((file.path as NSString).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    Image(systemName: file.group == .work ? "square.and.pencil" : "arrow.triangle.branch")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .accessibilityLabel(file.group.rawValue)
                    Text(file.status.replacingOccurrences(of: ".", with: ""))
                        .font(.system(size: 10, weight: .semibold).monospaced())
                        .foregroundStyle(statusColor(file))
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.leading, indent + 16)
            }
            .help(file.group.rawValue + " · " + (file.oldPath.map { $0 + " → " + file.path } ?? file.path))
        }
    }

    @ViewBuilder private var review: some View {
        if let file = model.file {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        let kind = PreviewKind(path: file.path)
                        Image(systemName: kind.symbol).foregroundStyle(kind.tint)
                            .font(.system(size: 17, weight: .medium)).frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text((file.path as NSString).lastPathComponent)
                                .font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text((file.path as NSString).deletingLastPathComponent.isEmpty
                                 ? model.repo?.url.lastPathComponent ?? ""
                                 : (file.path as NSString).deletingLastPathComponent)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }.help(file.path)
                        Spacer()
                        Picker("显示方式", selection: Binding(get: { model.mode }, set: model.changeMode)) {
                            ForEach(Workspace.Mode.allCases, id: \.self) { mode in
                                Label(mode.rawValue, systemImage: mode == .compare ? "rectangle.split.2x1" : "doc")
                                    .tag(mode)
                            }
                        }.labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                    HStack(spacing: 8) {
                        if file.layers.count > 1 {
                            Picker("Git 状态", selection: Binding(get: { model.layer }, set: model.chooseLayer)) {
                                ForEach(file.layers) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().fixedSize()
                        } else {
                            Text(model.layer.rawValue).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        if model.editing {
                            Button("保存", systemImage: "checkmark") { model.save() }.buttonStyle(DeskButton(emphasized: true)).disabled(!model.hasDraft)
                        } else {
                            if file.group == .work {
                                if file.layers.contains(.index) {
                                    Button("取消暂存", systemImage: "minus.circle") { model.stage(true) }.buttonStyle(DeskButton()).disabled(model.busy)
                                }
                                if file.layers.contains(where: { $0 != .index }) {
                                    Button("暂存", systemImage: "plus.circle") { model.stage(false) }.buttonStyle(DeskButton()).disabled(model.busy)
                                }
                            }
                            if model.canEdit {
                                Button("编辑", systemImage: "pencil") { model.beginEditing() }
                                    .buttonStyle(DeskButton()).help("编辑工作区文件")
                                    .disabled(model.loading || model.busy)
                            }
                        }
                    }.font(.caption)
                }.padding(.horizontal, 16).padding(.vertical, 11).background(DeskStyle.panel)
                Divider()
                if let comparison = model.comparison {
                    SwiftUI.Group {
                        if model.mode == .compare {
                            SplitComparison(comparison: comparison, path: file.path).id(model.layoutRevision)
                        } else {
                            fullFile(comparison)
                        }
                    }
                    .modifier(PreviewFeedback(revision: model.layoutRevision, mode: model.mode))
                } else if let issue = model.fileIssue {
                    empty("无法读取文件", icon: "exclamationmark.triangle", detail: issue) {
                        Button("重试") { model.loadFile() }
                    }
                } else {
                    ProgressView("加载文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if model.repo?.pending == true {
            ProgressView("正在读取工作树…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let issue = model.repo?.issue {
            empty("无法读取工作树", icon: "exclamationmark.triangle", detail: issue) {}
        } else {
            empty("选择变更文件", icon: "doc.text.magnifyingglass", detail: "可查看完整文件，或左右对比不同版本。") {}
        }
    }

    private func fullFile(_ comparison: Comparison) -> some View {
        VStack(spacing: 0) {
            HStack {
                if model.editing {
                    Label("正在编辑工作区", systemImage: "pencil")
                } else {
                    Picker("版本", selection: $model.fullVersion) {
                        Text(comparison.left.label).tag(Workspace.FullVersion.left)
                        Text(comparison.right.label).tag(Workspace.FullVersion.right)
                        if comparison.right.label != "工作区" { Text("工作区").tag(Workspace.FullVersion.disk) }
                    }.labelsHidden().fixedSize()
                }
                Spacer()
            }.font(.caption).padding(8).background(DeskStyle.panel)
            Divider()
            if model.editing {
                NativeText(text: model.draft, editable: true) { model.draft = $0 }
                    .id(model.layoutRevision)
            } else if let snapshot = model.fullSnapshot, let file = model.file {
                FilePreview(snapshot: snapshot, path: file.path)
                    .id(model.fullVersion)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let notice = model.notice {
                Text(notice).lineLimit(1)
            } else if model.directory != nil {
                Text(model.scanning ? "扫描中…" : "\(model.repos.count) 个工作树")
            } else {
                Text("本地工作区")
            }
            Spacer()
            if let file = model.file {
                Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(DeskStyle.panel)
    }

    private func sectionHeader(_ title: String, icon: String, count: Int?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer()
            if let count { Text(String(count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .foregroundStyle(DeskStyle.ink)
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func row<LabelView: View>(key: String, selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> LabelView) -> some View {
        Button(action: action) {
            content()
                .foregroundStyle(DeskStyle.ink)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(selected ? DeskStyle.selected : hoveredRow == key ? DeskStyle.canvas : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredRow = $0 ? key : (hoveredRow == key ? nil : hoveredRow) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func secondary(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.bottom, 5)
    }

    private func empty<Actions: View>(_ title: String, icon: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 27)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            actions()
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusColor(_ file: Change) -> Color {
        if file.layers.contains(.conflict) { return .orange }
        if file.status.contains("D") { return .red }
        if file.status.contains("A") || file.status == "?" { return .green }
        return .secondary
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

private struct PreviewFeedback: ViewModifier {
    let revision: UUID
    let mode: Workspace.Mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opacity = 1.0

    func body(content: Content) -> some View {
        content.opacity(opacity)
            .onAppear(perform: acknowledge)
            .onChange(of: revision) { _, _ in acknowledge() }
            .onChange(of: mode) { _, _ in acknowledge() }
    }

    private func acknowledge() {
        guard !reduceMotion else { opacity = 1; return }
        withAnimation(nil) { opacity = 0.83 }
        withAnimation(.easeOut(duration: 0.15)) { opacity = 1 }
    }
}

struct SplitComparison: View {
    let comparison: Comparison
    let path: String
    @State private var link = ComparisonText.ScrollLink()
    @State private var selectedHunk = 0
    @State private var revealRevision = 0

    var body: some View {
        let hunks = comparison.hunks
        VStack(spacing: 0) {
            if !comparison.rows.isEmpty {
                hunkBar(count: hunks.count)
                Divider()
            }
            HStack(spacing: 0) {
                pane(comparison.left, left: true, hunk: hunks.indices.contains(selectedHunk) ? hunks[selectedHunk] : hunks.first)
                DeskStyle.border.frame(width: 1)
                pane(comparison.right, left: false, hunk: hunks.indices.contains(selectedHunk) ? hunks[selectedHunk] : hunks.first)
            }
            if !comparison.aligned {
                Text("文件行数较多，显示两个完整版本。")
                    .font(.caption).foregroundStyle(.secondary).padding(5)
            }
        }
        .onChange(of: hunks) { _, _ in selectedHunk = 0 }
    }

    private func hunkBar(count: Int) -> some View {
        HStack(spacing: 6) {
            Text(count == 0 ? "没有行变更" : "\(count) 处改动 · \(min(selectedHunk + 1, count)) / \(count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer()
            hunkButton("上一处改动", icon: "chevron.up", step: -1, count: count)
            hunkButton("下一处改动", icon: "chevron.down", step: 1, count: count)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(DeskStyle.panel)
    }

    private func hunkButton(_ label: String, icon: String, step: Int, count: Int) -> some View {
        Button {
            guard count > 0 else { return }
            selectedHunk = (min(selectedHunk, count - 1) + step + count) % count
            revealRevision += 1
        } label: {
            Label(label, systemImage: icon).labelStyle(.iconOnly)
        }
        .buttonStyle(DeskButton())
        .help(label)
        .disabled(count == 0)
    }

    private func pane(_ snapshot: Snapshot, left: Bool, hunk: Range<Int>?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: left ? "arrow.uturn.backward" : "arrow.right")
                    .font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
                Text(snapshot.label).lineLimit(1)
                Spacer()
                if let size = snapshot.size, snapshot.text == nil {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).lineLimit(1)
                }
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(height: 34)
            .background(DeskStyle.panel)
            Divider()
            if comparison.aligned, !comparison.rows.isEmpty {
                ComparisonText(comparison: comparison, left: left, scrollLink: link,
                               activeHunk: hunk, revealRevision: revealRevision)
                    .accessibilityLabel(snapshot.label)
            } else {
                FilePreview(snapshot: snapshot, path: path)
            }
        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
