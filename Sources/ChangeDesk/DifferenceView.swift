import SwiftUI

struct DifferenceView: View {
    let comparison: Comparison
    let path: String
    let unified: Bool
    let sourceSide: SourceSide
    let viewport: TextViewport
    let jump: TextJump?
    let searchMarks: (surface: FileSearchSurface, marks: FileSearchMarks)?
    let isLoading: Bool
    let whitespaceDisabled: Bool
    let setIgnoresWhitespace: (Bool) -> Void
    @DeskState private var link = ComparisonText.ScrollLink()
    @DeskState private var selectedHunk = 0
    @DeskState private var revealRevision = 0

    var body: some View {
        let hunks = comparison.hunks
        let active = hunks.indices.contains(selectedHunk) ? hunks[selectedHunk] : hunks.first
        VStack(spacing: 0) {
            if !comparison.rows.isEmpty {
                hunkBar(count: hunks.count)
                Divider()
            }

            if unified, !comparison.rows.isEmpty {
                HStack(spacing: 7) {
                    versionName(comparison.left)
                    Image(systemName: "arrow.right").font(.caption2).accessibilityHidden(true)
                    versionName(comparison.right)
                    Spacer()
                }
                .padding(.horizontal, 13).frame(height: 34).background(DeskStyle.panel)
                Divider()
                ComparisonText(comparison: comparison, presentation: .unified, scrollLink: nil,
                               activeHunk: active, revealRevision: revealRevision, viewport: viewport, jump: jump,
                               searchMarks: marks(for: .unified))
                    .accessibilityLabel("行内代码差异")
            } else {
                HStack(spacing: 0) {
                    pane(comparison.left, presentation: .before, hunk: active)
                    Divider()
                    pane(comparison.right, presentation: .after, hunk: active)
                }
                if !comparison.aligned || unified {
                    Divider()
                    Text(!comparison.aligned ? "文件行数较多，正在显示两个完整版本。" :
                            "此文件使用并排版本预览。")
                        .font(.caption).foregroundStyle(.secondary).padding(7)
                }
            }
        }
        .onChange(of: hunks) { _, _ in selectedHunk = 0 }
    }

    private func hunkBar(count: Int) -> some View {
        let rows = comparison.rows.lazy.filter(\.changed)
        let additions = rows.filter { $0.rightNumber != nil }.count
        let deletions = rows.filter { $0.leftNumber != nil }.count
        return HStack(spacing: 10) {
            Text("+\(additions)")
                .foregroundStyle(DeskStyle.added).accessibilityLabel("新增 \(additions) 行")
            Text("−\(deletions)")
                .foregroundStyle(DeskStyle.removed).accessibilityLabel("删除 \(deletions) 行")
            Toggle("忽略行内空白", isOn: Binding(get: { comparison.ignoresWhitespace }, set: setIgnoresWhitespace))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("忽略缩进、空格和制表符差异")
                .disabled(isLoading || whitespaceDisabled)
            Spacer()
            if isLoading {
                ProgressView().controlSize(.mini).accessibilityLabel("正在更新差异")
            }
            Text(count == 0 ? (comparison.ignoresWhitespace ? "忽略空白后无行变更" : "没有行变更") :
                 "改动 \(min(selectedHunk + 1, count)) / \(count)")
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            HStack(spacing: 4) {
                hunkButton("上一处改动", icon: "chevron.up", step: -1, count: count)
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                hunkButton("下一处改动", icon: "chevron.down", step: 1, count: count)
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 13)
        .frame(height: 36)
        .background(.bar)
    }

    private func hunkButton(_ label: String, icon: String, step: Int, count: Int) -> some View {
        Button {
            guard count > 0 else { return }
            selectedHunk = (min(selectedHunk, count - 1) + step + count) % count
            revealRevision += 1
        } label: {
            Label(label, systemImage: icon).labelStyle(.iconOnly)
                .frame(width: 23, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .disabled(count == 0)
    }

    private func versionName(_ snapshot: Snapshot) -> some View {
        Text(snapshot.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
    }

    private func pane(_ snapshot: Snapshot, presentation: ComparisonText.Presentation, hunk: Range<Int>?) -> some View {
        let observes = presentation == .before ? sourceSide == .before : sourceSide == .after
        let searchMarks = marks(for: presentation == .before ? .before : .after)
        return VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: presentation == .before ? "arrow.uturn.backward" : "arrow.right")
                    .font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                versionName(snapshot)
                Spacer()
                if let size = snapshot.size, snapshot.text == nil {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 13).frame(height: 34).background(DeskStyle.panel)
            Divider()
            if !comparison.rows.isEmpty {
                ComparisonText(comparison: comparison, presentation: presentation, scrollLink: link,
                               activeHunk: hunk, revealRevision: revealRevision, viewport: observes ? viewport : nil, jump: jump,
                               searchMarks: searchMarks)
                    .accessibilityLabel(snapshot.label)
            } else {
                FilePreview(snapshot: snapshot, path: path, viewport: observes ? viewport : nil,
                            jump: observes ? jump : nil, searchMarks: searchMarks)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func marks(for surface: FileSearchSurface) -> FileSearchMarks? {
        searchMarks?.surface == surface ? searchMarks?.marks : nil
    }
}
