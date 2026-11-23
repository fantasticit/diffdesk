import AppKit
import AVKit
import ImageIO
import PDFKit
import QuickLookUI
import SwiftUI

private extension PreviewFile {
    var identity: PreviewIdentity { PreviewIdentity(url: url, revision: revision) }
}

private struct PreviewIdentity: Hashable {
    let url: URL
    let revision: Date?
}

extension PreviewKind {
    var symbol: String {
        switch self {
        case .text: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .video: "film"
        case .audio: "waveform"
        case .archive: "archivebox"
        case .document: "doc.text"
        case .other: "doc"
        }
    }

    var tint: Color {
        switch self {
        case .text: .indigo
        case .image: .teal
        case .pdf: .pink
        case .video: .purple
        case .audio: .orange
        case .archive: .brown
        case .document: .blue
        case .other: .secondary
        }
    }
}

struct FilePreview: View {
    let snapshot: Snapshot
    let path: String
    var viewport: TextViewport?
    var jump: TextJump?
    var searchMarks: FileSearchMarks?

    var body: some View {
        SwiftUI.Group {
            if !snapshot.present {
                placeholder("此版本没有该文件", symbol: "doc.badge.minus")
            } else if let text = snapshot.text {
                NativeText(text: text, viewport: viewport, jump: jump, searchMarks: searchMarks)
            } else if let file = snapshot.preview {
                switch snapshot.kind {
                case .image: ImagePreview(file: file, description: path)
                case .pdf: PDFPreview(file: file)
                case .audio, .video: MediaPreview(file: file, audio: snapshot.kind == .audio)
                default: SystemPreview(file: file)
                }
            } else {
                placeholder(snapshot.message ?? "无法预览此文件", symbol: "doc.questionmark")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(snapshot.label)
    }

    private func placeholder(_ message: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 25, weight: .light))
            Text(message).font(.callout).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeskStyle.canvas)
    }
}

private struct ImagePreview: View {
    let file: PreviewFile
    let description: String
    @DeskState private var image: NSImage?
    @DeskState private var loaded = false
    @DeskState private var zoom = false

    var body: some View {
        SwiftUI.Group {
            if let image {
                GeometryReader { proxy in
                    if zoom {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image).padding(20)
                        }
                    } else {
                        Image(nsImage: image).resizable().scaledToFit().padding(20)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .accessibilityLabel(description)
                .overlay(alignment: .bottomTrailing) {
                    Button { zoom.toggle() } label: {
                        Image(systemName: zoom ? "arrow.down.right.and.arrow.up.left" : "plus.magnifyingglass")
                    }
                    .help(zoom ? "适应窗口" : "放大图片")
                    .accessibilityLabel(zoom ? "适应窗口" : "放大图片")
                    .padding(9)
                }
            } else if loaded {
                SystemPreview(file: file)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DeskStyle.canvas)
        .task(id: file.identity) {
            image = nil
            loaded = false
            let decoded = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else { return nil as CGImage? }
                let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                               kCGImageSourceCreateThumbnailWithTransform: true,
                               kCGImageSourceThumbnailMaxPixelSize: 2600] as CFDictionary
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
            }.value
            guard !Task.isCancelled else { return }
            if let decoded { image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height)) }
            loaded = true
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let file: PreviewFile

    final class Coordinator {
        var file: PreviewFile?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .controlBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.file?.identity != file.identity else { return }
        view.document = PDFDocument(url: file.url)
        context.coordinator.file = file
    }
}

private struct MediaPreview: NSViewRepresentable {
    let file: PreviewFile
    let audio: Bool

    final class Coordinator {
        var file: PreviewFile?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.controlsStyle = audio ? .inline : .floating
        if context.coordinator.file?.identity != file.identity {
            view.player?.pause()
            view.player = AVPlayer(url: file.url)
            context.coordinator.file = file
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
    }
}

private struct SystemPreview: NSViewRepresentable {
    let file: PreviewFile

    final class Coordinator {
        var file: PreviewFile?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            return NSTextField(labelWithString: "快速查看不可用")
        }
        view.autostarts = true
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let preview = view as? QLPreviewView, context.coordinator.file?.identity != file.identity else { return }
        preview.previewItem = file.url as NSURL
        preview.refreshPreviewItem()
        context.coordinator.file = file
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        (view as? QLPreviewView)?.close()
    }
}
