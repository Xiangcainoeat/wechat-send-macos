import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift make-icon.swift <output.iconset>")
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, size) in variants {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor(red: 0.08, green: 0.43, blue: 0.29, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect.insetBy(dx: CGFloat(size) * 0.06, dy: CGFloat(size) * 0.06),
                 xRadius: CGFloat(size) * 0.20,
                 yRadius: CGFloat(size) * 0.20).fill()

    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.48, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let symbolRect = NSRect(
            x: (CGFloat(size) - symbolSize.width) / 2,
            y: (CGFloat(size) - symbolSize.height) / 2,
            width: symbolSize.width,
            height: symbolSize.height
        )
        NSColor.white.set()
        symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
    }
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not render icon")
    }
    try png.write(to: output.appendingPathComponent(name))
}
