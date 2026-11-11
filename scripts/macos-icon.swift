import CoreGraphics
import Foundation
import ImageIO

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func writeIcon(_ size: Int, _ suffix: String, pixels: Int) {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 100, y: CGFloat(pixels) / 100)
    context.setFillColor(red: 197 / 255, green: 248 / 255, blue: 132 / 255, alpha: 1)
    context.addPath(CGPath(roundedRect: CGRect(x: 7, y: 7, width: 86, height: 86),
                           cornerWidth: 21, cornerHeight: 21, transform: nil))
    context.fillPath()
    context.setFillColor(red: 25 / 255, green: 35 / 255, blue: 16 / 255, alpha: 1)
    for (x, height) in [(34.0, 25.0), (47.0, 47.0), (60.0, 34.0)] {
        let bar = CGRect(x: x, y: 50 - height / 2, width: 6, height: height)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()
    }
    let path = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
    let destination = CGImageDestinationCreateWithURL(path as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination), "Could not write app icon")
}

for size in [16, 32, 128, 256, 512] {
    writeIcon(size, "", pixels: size)
    writeIcon(size, "@2x", pixels: size * 2)
}
