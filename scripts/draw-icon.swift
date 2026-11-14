import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let sizes = [16, 32, 128, 256, 512]
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func render(pixels: Int, url: URL) {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: pixels * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)

    func rounded(_ box: CGRect, radius: CGFloat, fill: CGColor) {
        context.setFillColor(fill)
        context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    let tile = CGRect(x: 88, y: 88, width: 848, height: 848)
    rounded(tile.offsetBy(dx: 0, dy: -14), radius: 188, fill: color(0x153c3b, alpha: 0.22))
    rounded(tile, radius: 188, fill: color(0x173c3b))
    rounded(tile.insetBy(dx: 10, dy: 10), radius: 180, fill: color(0x1a4643))
    rounded(CGRect(x: 249, y: 260, width: 239, height: 504), radius: 54, fill: color(0xe8f5ee))
    rounded(CGRect(x: 536, y: 260, width: 239, height: 504), radius: 54, fill: color(0x86e1ca))
    for (x, strong, faint) in [(CGFloat(302), UInt32(0x376761), UInt32(0xa2c7bb)),
                                (CGFloat(589), UInt32(0x1b5b53), UInt32(0x4f9c8c))] {
        rounded(CGRect(x: x, y: 622, width: 133, height: 32), radius: 16, fill: color(strong))
        rounded(CGRect(x: x, y: 544, width: 103, height: 32), radius: 16, fill: color(faint))
    }
    rounded(CGRect(x: 318, y: 392, width: 100, height: 32), radius: 16, fill: color(0x376761))
    rounded(CGRect(x: 605, y: 392, width: 100, height: 32), radius: 16, fill: color(0x1b5b53))
    rounded(CGRect(x: 639, y: 358, width: 32, height: 100), radius: 16, fill: color(0x1b5b53))

    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
}

for size in sizes {
    render(pixels: size, url: output.appendingPathComponent("icon_\(size)x\(size).png"))
    render(pixels: size * 2, url: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
