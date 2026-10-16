// Draws Paper Plane's app icon with Core Graphics and writes every size macOS needs, plus
// Contents.json, into an .appiconset folder. Reproducible: same script, same pixels.
// Usage: swift scripts/make-icon.swift app/PaperPlane/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws the icon into a square context of side `size` (y axis pointing up).
func drawIcon(in context: CGContext, size: CGFloat) {
    let unit = size / 1024
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * unit, y: (1024 - y) * unit) // design coordinates have y pointing down
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
    }

    // The macOS icon shape: an 824-point rounded square on the 1024 grid, with a soft shadow.
    let tile = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 28 * unit, color: color(0, 0, 0, 0.28))
    context.addPath(tilePath)
    context.setFillColor(color(0.16, 0.42, 0.95))
    context.fillPath()
    context.restoreGState()

    // Sky gradient, light at the top.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let sky = CGGradient(colorsSpace: colorSpace,
                         colors: [color(0.38, 0.74, 1.00), color(0.16, 0.42, 0.95), color(0.20, 0.27, 0.82)] as CFArray,
                         locations: [0, 0.55, 1])!
    context.drawLinearGradient(sky, start: point(512, 100), end: point(512, 924), options: [])

    // A faint flight path curving up to the plane.
    let trail = CGMutablePath()
    trail.move(to: point(190, 790))
    trail.addCurve(to: point(470, 560), control1: point(300, 800), control2: point(360, 640))
    context.addPath(trail)
    context.setStrokeColor(color(1, 1, 1, 0.38))
    context.setLineWidth(18 * unit)
    context.setLineCap(.round)
    context.setLineDash(phase: 0, lengths: [2 * unit, 40 * unit])
    context.strokePath()
    context.setLineDash(phase: 0, lengths: [])

    // The plane, pointing up and to the right: a bright upper wing, a shaded underside and a
    // fold, with a shadow that lifts it off the sky.
    let nose = point(800, 230)
    let wingTip = point(250, 470)
    let tail = point(480, 560)
    let keel = point(560, 790)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18 * unit), blur: 36 * unit, color: color(0.05, 0.10, 0.35, 0.45))
    let body = CGMutablePath()
    body.addLines(between: [nose, wingTip, tail, keel, nose])
    context.addPath(body)
    context.setFillColor(color(1, 1, 1))
    context.fillPath()
    context.restoreGState()

    let underside = CGMutablePath()
    underside.addLines(between: [nose, tail, keel, nose])
    context.addPath(underside)
    context.setFillColor(color(0.80, 0.87, 0.98))
    context.fillPath()

    let fold = CGMutablePath()
    fold.addLines(between: [nose, point(540, 610)])
    context.addPath(fold)
    context.setStrokeColor(color(0.62, 0.72, 0.92))
    context.setLineWidth(10 * unit)
    context.setLineCap(.round)
    context.strokePath()
    context.restoreGState()
}

/// `toolbar` draws the tile filling the whole image, as browser toolbar icons are; `grey` drains
/// its colour and fades it, for the extension's "nothing found" state.
func writePNG(size: Int, to url: URL, toolbar: Bool = false, grey: Bool = false) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }
    context.interpolationQuality = .high
    if toolbar {
        // The 824-point tile (from 100 to 924 on the 1024 grid) scaled to the full image.
        let scale = 1024.0 / 824.0
        context.translateBy(x: -100 * CGFloat(size) / 824, y: -100 * CGFloat(size) / 824)
        context.scaleBy(x: scale, y: scale)
    }
    drawIcon(in: context, size: CGFloat(size))
    if grey, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
        for offset in stride(from: 0, to: context.bytesPerRow * size, by: 4) {
            let luminance = 0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.114 * Double(pixels[offset + 2])
            for channel in 0..<4 { // still premultiplied after fading every channel alike
                let value = channel == 3 ? Double(pixels[offset + 3]) : luminance
                pixels[offset + channel] = UInt8(min(255, value * 0.55))
            }
        }
    }
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--extension" {
    // The extension's icons: icon-N.png in colour, idle-N.png grey.
    let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for size in [16, 32, 48, 128] {
        try writePNG(size: size, to: folder.appendingPathComponent("icon-\(size).png"), toolbar: true)
        try writePNG(size: size, to: folder.appendingPathComponent("idle-\(size).png"), toolbar: true, grey: true)
    }
    print("Wrote 8 extension icons to \(folder.path)")
    exit(0)
}

guard CommandLine.arguments.count == 2 else {
    print("usage: swift scripts/make-icon.swift <AppIcon.appiconset folder>")
    print("       swift scripts/make-icon.swift --extension <icons folder>")
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try writePNG(size: points * scale, to: folder.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: folder.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(folder.path)")
