import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(red: 0.025, green: 0.06, blue: 0.1, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let background = NSBezierPath(roundedRect: NSRect(x: 12, y: 12, width: 1000, height: 1000), xRadius: 220, yRadius: 220)
NSGradient(starting: NSColor(red: 0.06, green: 0.15, blue: 0.24, alpha: 1), ending: NSColor(red: 0.015, green: 0.035, blue: 0.065, alpha: 1))!.draw(in: background, angle: -65)
for angle: CGFloat in [-48, 48, 0] {
    NSGraphicsContext.saveGraphicsState()
    let transform = AffineTransform(translationByX: 512, byY: 512)
    (transform as NSAffineTransform).concat()
    let rotation = NSAffineTransform(); rotation.rotate(byDegrees: angle); rotation.concat()
    let ellipse = NSBezierPath(ovalIn: NSRect(x: -340, y: -145, width: 680, height: 290))
    ellipse.lineWidth = 26
    NSColor(red: 0.31, green: 0.92, blue: 0.78, alpha: angle == 0 ? 0.95 : 0.65).setStroke()
    ellipse.stroke()
    NSGraphicsContext.restoreGraphicsState()
}
let phone = NSBezierPath(roundedRect: NSRect(x: 412, y: 325, width: 200, height: 374), xRadius: 35, yRadius: 35)
NSColor(red: 0.07, green: 0.12, blue: 0.18, alpha: 1).setFill(); phone.fill()
phone.lineWidth = 17; NSColor.white.setStroke(); phone.stroke()
let island = NSBezierPath(roundedRect: NSRect(x: 477, y: 655, width: 70, height: 14), xRadius: 7, yRadius: 7)
NSColor.white.setFill(); island.fill()
image.unlockFocus()
let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
func resizedPNG(_ pixels: Int) -> Data {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(cg, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}
for platform in ["iOS", "macOS"] {
    let catalog = root.appendingPathComponent("\(platform)/Assets.xcassets")
    let directory = catalog.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var icons: [[String: Any]] = []
    let sizes = platform == "iOS" ? [20, 29, 40, 60] : [16, 32, 128, 256, 512]
    let scales = platform == "iOS" ? [2, 3] : [1, 2]
    for size in sizes {
        for scale in scales {
            let filename = "icon-\(size)@\(scale)x.png"
            try resizedPNG(size * scale).write(to: directory.appendingPathComponent(filename))
            icons.append(["filename": filename, "idiom": platform == "iOS" ? "iphone" : "mac",
                          "size": "\(size)x\(size)", "scale": "\(scale)x"])
        }
    }
    if platform == "iOS" {
        try resizedPNG(1024).write(to: directory.appendingPathComponent("AppIcon.png"))
        icons.append(["filename": "AppIcon.png", "idiom": "ios-marketing", "size": "1024x1024", "scale": "1x"])
    } else {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("AppIcon.png"))
    }
    let info: [String: Any] = ["author": "xcode", "version": 1]
    try JSONSerialization.data(withJSONObject: ["images": icons, "info": info], options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("Contents.json"))
    try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted])
        .write(to: catalog.appendingPathComponent("Contents.json"))
}
