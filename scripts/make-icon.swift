// Renders the plugin icon set. Run through scripts/make-assets.sh.
//
// Kept in the repo so the artwork is reproducible rather than an opaque binary
// blob: a gradient calendar tile plus a completion check, drawn with AppKit.
import AppKit
import Foundation

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let scale = size / 512
    func s(_ value: CGFloat) -> CGFloat { value * scale }

    // Tile with the Calendar red → Reminders orange gradient.
    let tile = NSBezierPath(
        roundedRect: NSRect(x: s(10), y: s(10), width: s(492), height: s(492)),
        xRadius: s(112),
        yRadius: s(112)
    )
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),
    ])
    gradient?.draw(in: tile, angle: -90)

    // Calendar page.
    let page = NSRect(x: s(112), y: s(126), width: s(288), height: s(266))
    NSColor.white.setFill()
    NSBezierPath(roundedRect: page, xRadius: s(30), yRadius: s(30)).fill()

    // Header band, squared off at the bottom so it reads as a bar not a pill.
    let bandHeight = s(62)
    let band = NSRect(x: page.minX, y: page.maxY - bandHeight, width: page.width, height: bandHeight)
    NSColor(srgbRed: 0.85, green: 0.09, blue: 0.16, alpha: 1).setFill()
    let bandPath = NSBezierPath(roundedRect: band, xRadius: s(30), yRadius: s(30))
    bandPath.fill()
    NSBezierPath(rect: NSRect(x: band.minX, y: band.minY, width: band.width, height: s(30))).fill()

    // Two binder rings above the page.
    NSColor(srgbRed: 0.85, green: 0.09, blue: 0.16, alpha: 1).setFill()
    for x in [page.minX + s(72), page.maxX - s(96)] {
        NSBezierPath(
            roundedRect: NSRect(x: x, y: page.maxY - s(6), width: s(24), height: s(52)),
            xRadius: s(12),
            yRadius: s(12)
        ).fill()
    }

    // Completion check.
    let check = NSBezierPath()
    check.move(to: NSPoint(x: page.minX + s(78), y: page.minY + s(96)))
    check.line(to: NSPoint(x: page.minX + s(126), y: page.minY + s(50)))
    check.line(to: NSPoint(x: page.maxX - s(72), y: page.minY + s(164)))
    check.lineWidth = s(34)
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1).setStroke()
    check.stroke()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to path: String) throws {
    guard let tiff = image.tiffRepresentation,
          let target = NSBitmapImageRep(
              bitmapDataPlanes: nil,
              pixelsWide: pixels,
              pixelsHigh: pixels,
              bitsPerSample: 8,
              samplesPerPixel: 4,
              hasAlpha: true,
              isPlanar: false,
              colorSpaceName: .deviceRGB,
              bytesPerRow: 0,
              bitsPerPixel: 0
          )
    else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not create bitmap"])
    }
    target.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = target.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "could not encode PNG"])
    }
    try png.write(to: URL(fileURLWithPath: path))
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon <output-directory>\n".utf8))
    exit(2)
}
let directory = arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

let artwork = renderIcon(size: 512)
try writePNG(artwork, pixels: 512, to: "\(directory)/mac-calendar.png")
try writePNG(artwork, pixels: 128, to: "\(directory)/composer-icon.png")
try writePNG(artwork, pixels: 64, to: "\(directory)/mac-calendar-small.png")
print("wrote mac-calendar.png (512), composer-icon.png (128), mac-calendar-small.png (64) to \(directory)")
