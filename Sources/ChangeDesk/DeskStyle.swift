import SwiftUI

enum DeskStyle {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.67, green: 0.66, blue: 1, alpha: 1)
        }
        return NSColor(srgbRed: 0.30, green: 0.25, blue: 0.72, alpha: 1)
    })
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let added = Color(nsColor: DiffTone.addition.ink)
    static let removed = Color(nsColor: DiffTone.deletion.ink)
}
