import AppKit

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let plate = NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 188, yRadius: 188)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.15, blue: 0.27, alpha: 1),
                              ending: NSColor(srgbRed: 0.12, green: 0.34, blue: 0.39, alpha: 1))!
    gradient.draw(in: plate, angle: 38)
    NSColor(srgbRed: 0.43, green: 0.92, blue: 0.83, alpha: 1).setFill()
    for (i, height) in [104, 202, 295, 388, 321, 201, 126].enumerated() {
        let bar = NSRect(x: 244 + i * 78, y: (1024 - height) / 2, width: 60, height: height)
        NSBezierPath(roundedRect: bar, xRadius: 28, yRadius: 28).fill()
    }
    return true
}
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
