import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes = [16, 32, 128, 256, 512]
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func render(pixels: Int, url: URL) {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: pixels * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)

    func path(_ box: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    func fill(_ shape: CGPath, _ shade: CGColor) {
        context.setFillColor(shade)
        context.addPath(shape)
        context.fillPath()
    }

    func gradient(_ shape: CGPath, _ colors: [CGColor], start: CGPoint, end: CGPoint) {
        context.saveGState()
        context.addPath(shape)
        context.clip()
        let ramp = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
        context.drawLinearGradient(ramp, start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    func shadow(_ shape: CGPath, from shade: CGColor, offset: CGFloat, blur: CGFloat) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: offset), blur: blur, color: shade)
        fill(shape, shade)
        context.restoreGState()
    }

    let box = CGRect(x: 86, y: 86, width: 852, height: 852)
    let tile = path(box, 196)
    shadow(tile, from: color(0x100A2C, alpha: 0.45), offset: -17, blur: 29)
    gradient(tile, [color(0x6559BD), color(0x393171), color(0x21193F)],
             start: CGPoint(x: 150, y: 918), end: CGPoint(x: 878, y: 110))
    gradient(tile.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 1),
             [color(0xD6CDFF, alpha: 0.7), color(0x6D60A7, alpha: 0.35)],
             start: CGPoint(x: 500, y: 930), end: CGPoint(x: 500, y: 90))

    // The panes retain the comparison's silhouette even in a 16-pixel list icon.
    for (x, isAdded) in [(CGFloat(219), false), (CGFloat(531), true)] {
        let y: CGFloat = isAdded ? 263 : 298
        let pane = path(CGRect(x: x, y: y, width: 274, height: 463), 62)
        shadow(pane, from: color(0x170E3B, alpha: 0.38), offset: -13, blur: 19)
        let shades = isAdded ? [color(0xF3FFF9), color(0xB0F2D8), color(0x72BFAE)] :
            [color(0xFFF5FF), color(0xF1C0E6), color(0xAF8BCD)]
        gradient(pane, shades, start: CGPoint(x: x + 36, y: y + 449), end: CGPoint(x: x + 227, y: y + 13))
        let ink = isAdded ? color(0x28736B) : color(0x815184)
        fill(path(CGRect(x: x + 65, y: y + 333, width: 144, height: 20), 10), ink.copy(alpha: 0.44)!)
        fill(path(CGRect(x: x + 65, y: y + 285, width: 101, height: 18), 9), ink.copy(alpha: 0.27)!)
        fill(path(CGRect(x: x + 69, y: y + 126, width: 136, height: 32), 16), ink)
        if isAdded {
            fill(path(CGRect(x: x + 121, y: y + 74, width: 32, height: 136), 16), ink)
        }
    }

    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
}

for size in sizes {
    render(pixels: size, url: output.appendingPathComponent("icon_\(size)x\(size).png"))
    render(pixels: size * 2, url: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
