import SwiftUI

enum DeskStyle {
    static let accent = Color(red: 0.08, green: 0.53, blue: 0.48)
    static let sidebar = adaptive(0xf0f4f3, 0x202929)
    static let canvas = adaptive(0xf3f6f5, 0x1c2424)
    static let panel = adaptive(0xfbfcfc, 0x262e2f)
    static let content = adaptive(0xffffff, 0x22292a)
    static let border = adaptive(0xdde6e4, 0x374446)
    static let selected = adaptive(0xdcefeb, 0x294844)
    static let ink = adaptive(0x243432, 0xe4eeeb)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

struct DeskButton: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, emphasized: emphasized)
    }

    private struct Face: View {
        let configuration: Configuration
        let emphasized: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 9)
                .frame(minHeight: 28)
                .foregroundStyle(emphasized ? Color.white : DeskStyle.ink)
                .background(emphasized ? DeskStyle.accent.opacity(configuration.isPressed ? 0.75 : 1)
                            : configuration.isPressed ? DeskStyle.selected : hover && enabled ? DeskStyle.canvas : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? 1 : 0.43)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}
