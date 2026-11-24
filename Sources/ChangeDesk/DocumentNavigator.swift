import SwiftUI

struct OutlineSource: Equatable, Sendable {
    let path: String
    let text: String
    let side: SourceSide
}

private struct MinimapData: Equatable, Sendable {
    struct Mark: Equatable, Sendable {
        var indent = 0
        var length = 0
        var addition = false
        var deletion = false
    }

    var count = 0
    var samples: [Mark] = []

    static func create(text: String, comparison: Comparison?, unified: Bool) -> Self {
        if let comparison, !comparison.rows.isEmpty {
            if unified {
                let lines = comparison.unifiedLines()
                return sampling(count: lines.count) { index in
                    let line = lines[index]
                    return (line.code, line.tone == .addition, line.tone == .deletion)
                }
            }
            return sampling(count: comparison.rows.count) { index in
                let row = comparison.rows[index]
                return (row.right ?? row.left ?? "", row.changed && row.right != nil, row.changed && row.left != nil)
            }
        }
        let lines = text.components(separatedBy: "\n")
        return sampling(count: lines.count) { (lines[$0], false, false) }
    }

    private static func sampling(count: Int, line: (Int) -> (String, Bool, Bool)) -> Self {
        let target = min(count, 420)
        guard target > 0 else { return Self() }
        var samples = Array(repeating: Mark(), count: target)
        for number in 0..<count {
            let (text, plus, minus) = line(number)
            let prefix = text.prefix(100)
            let indent = prefix.prefix { $0 == " " || $0 == "\t" }.count
            let length = prefix.count - indent
            let index = number * target / count
            if length > samples[index].length {
                samples[index].length = length
                samples[index].indent = min(20, indent)
            }
            samples[index].addition = samples[index].addition || plus
            samples[index].deletion = samples[index].deletion || minus
        }
        return Self(count: count, samples: samples)
    }
}

struct DocumentNavigator<Editor: View>: View {
    let source: OutlineSource
    let comparison: Comparison?
    let unified: Bool
    let canSwitchSide: Bool
    @Binding var side: SourceSide
    @Binding var showOutline: Bool
    let viewport: TextViewport
    let jump: (TextJump.Target) -> Void
    @ViewBuilder let editor: () -> Editor
    @DeskState private var minimap = MinimapData()

    private struct MapKey: Equatable {
        let comparisonID: UUID?
        let text: String?
        let unified: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            let separate = geometry.size.width >= 640
            HStack(spacing: 0) {
                editor()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if minimap.count > 0 {
                    Divider()
                    DocumentMinimap(map: minimap, viewport: viewport) { jump(.displayRow($0)) }
                }
                if showOutline && separate {
                    Divider()
                    outline(closeAfterSelection: false)
                }
            }
            .overlay(alignment: .trailing) {
                if showOutline && !separate {
                    outline(closeAfterSelection: true)
                        .background(DeskStyle.panel)
                        .overlay(alignment: .leading) { Divider() }
                        .shadow(color: .black.opacity(0.16), radius: 7, x: -3, y: 0)
                }
            }
        }
        .task(id: MapKey(comparisonID: comparison?.id,
                         text: comparison?.rows.isEmpty == false ? nil : source.text, unified: unified)) {
            let comparison = comparison
            let text = source.text
            let unified = unified
            let data = await Task.detached(priority: .utility) {
                MinimapData.create(text: text, comparison: comparison, unified: unified)
            }.value
            guard !Task.isCancelled else { return }
            minimap = data
        }
    }

    private func outline(closeAfterSelection: Bool) -> some View {
        OutlinePanel(source: source, canSwitchSide: canSwitchSide, side: $side, showOutline: $showOutline) { line in
            jump(.source(line: line, side: source.side))
            if closeAfterSelection { showOutline = false }
        }
        .frame(width: 205)
    }
}

private struct OutlinePanel: View {
    let source: OutlineSource
    let canSwitchSide: Bool
    @Binding var side: SourceSide
    @Binding var showOutline: Bool
    let reveal: (Int) -> Void
    @DeskState private var symbols: [OutlineSymbol] = []
    @DeskState private var query = ""
    @DeskState private var selectedLine: Int?
    @DeskState private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文件大纲").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("关闭大纲", systemImage: "xmark") { showOutline = false }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 35)
            if canSwitchSide {
                Picker("大纲版本", selection: $side) {
                    ForEach(SourceSide.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 10).padding(.bottom, 7)
            }
            TextField("筛选符号", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 10).padding(.bottom, 8)
                .disabled(symbols.isEmpty)
            Divider()
            let visible = query.isEmpty ? symbols : symbols.filter { $0.title.localizedStandardContains(query) }
            if !loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                Text(query.isEmpty ? "没有可识别的标题或符号" : "没有匹配的符号")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { symbol in symbolRow(symbol) }
                    }
                    .padding(6)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(DeskStyle.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文件大纲")
        .onChange(of: source.path) { _, _ in query = "" }
        .task(id: source) {
            loaded = false
            selectedLine = nil
            let source = source
            let result = await Task.detached(priority: .userInitiated) {
                FileOutline.parse(source.text, path: source.path)
            }.value
            guard !Task.isCancelled else { return }
            symbols = result
            loaded = true
        }
    }

    private func symbolRow(_ symbol: OutlineSymbol) -> some View {
        let (image, tint): (String, Color) = switch symbol.kind {
        case .heading: ("text.alignleft", DeskStyle.accent)
        case .type: ("cube", DeskStyle.accent)
        case .function: ("function", .teal)
        case .property: ("number", .secondary)
        }
        return Button {
            selectedLine = symbol.line
            reveal(symbol.line)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: image).foregroundStyle(tint)
                    .frame(width: 13).accessibilityHidden(true)
                Text(symbol.title)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 3)
                Text(symbol.line.formatted())
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.leading, 5 + CGFloat(min(symbol.depth, 4)) * 8)
            .padding(.trailing, 5)
            .frame(height: 26)
            .background(selectedLine == symbol.line ? DeskStyle.accent.opacity(0.14) : .clear,
                        in: .rect(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(symbol.title)，第 \(symbol.line) 行")
        .accessibilityAddTraits(selectedLine == symbol.line ? .isSelected : [])
        .help(symbol.title)
    }
}

private struct DocumentMinimap: View {
    let map: MinimapData
    @ObservedObject var viewport: TextViewport
    let reveal: (Int) -> Void
    @DeskState private var lastRequestedRow: Int?

    var body: some View {
        GeometryReader { geometry in
            let height = min(max(1, geometry.size.height - 14), max(14, CGFloat(map.count) * 2.45))
            let position = viewport.position
            MinimapInk(samples: map.samples).equatable()
            .overlay(alignment: .topLeading) {
                let start = min(max(0, 1 - position.length), position.start)
                RoundedRectangle(cornerRadius: 3)
                    .fill(DeskStyle.accent.opacity(0.13))
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(DeskStyle.accent.opacity(0.46)) }
                    .frame(height: min(height, max(5, height * position.length)))
                    .offset(y: height * start)
                    .padding(.horizontal, 1)
                    .allowsHitTesting(false)
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let row = min(map.count - 1, max(0, Int(value.location.y / height * CGFloat(map.count))))
                guard lastRequestedRow != row else { return }
                lastRequestedRow = row
                reveal(row)
            }.onEnded { _ in lastRequestedRow = nil })
            .padding(.top, 7)
        }
        .frame(width: 56)
        .background(DeskStyle.panel)
        .help("点击或拖动缩略图跳转")
        .accessibilityElement()
        .accessibilityLabel("代码缩略图")
        .accessibilityValue("可见范围 \(Int(viewport.position.start * 100))%")
        .accessibilityAdjustableAction { direction in
            let offset = max(1, map.count / 10)
            let current = Int(viewport.position.start * CGFloat(map.count))
            switch direction {
            case .increment: reveal(min(map.count - 1, current + offset))
            case .decrement: reveal(max(0, current - offset))
            @unknown default: break
            }
        }
    }
}

private struct MinimapInk: View, Equatable {
    let samples: [MinimapData.Mark]

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let step = size.height / CGFloat(samples.count)
            for (index, mark) in samples.enumerated() {
                let y = CGFloat(index) * step
                let strokeHeight = min(1.5, max(0.65, step * 0.68))
                let x = 9 + CGFloat(mark.indent) * 0.32
                let width = min(size.width - x - 6, CGFloat(mark.length) * 0.66)
                if width > 0 {
                    let tint = mark.addition ? DeskStyle.added :
                        mark.deletion ? DeskStyle.removed : Color.secondary
                    let stroke = CGRect(x: x, y: y, width: width, height: strokeHeight)
                    context.fill(Path(roundedRect: stroke, cornerRadius: 0.4),
                                 with: .color(tint.opacity(mark.addition || mark.deletion ? 0.78 : 0.46)))
                }
                if mark.deletion {
                    context.fill(Path(CGRect(x: 2, y: y, width: 2, height: max(1, step))), with: .color(DeskStyle.removed))
                }
                if mark.addition {
                    context.fill(Path(CGRect(x: 5, y: y, width: 2, height: max(1, step))), with: .color(DeskStyle.added))
                }
            }
        }
    }
}
