import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Expected PNG destination") }
let image = NSImage(size: NSSize(width: 660, height: 400))
image.lockFocus()
NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 660, height: 400).fill()
let title = "Drag msgblast to Applications" as NSString
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 25, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)
]
let size = title.size(withAttributes: attributes)
title.draw(at: NSPoint(x: (660 - size.width) / 2, y: 316), withAttributes: attributes)
NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 3
arrow.move(to: NSPoint(x: 295, y: 190)); arrow.line(to: NSPoint(x: 365, y: 190))
arrow.move(to: NSPoint(x: 353, y: 202)); arrow.line(to: NSPoint(x: 365, y: 190)); arrow.line(to: NSPoint(x: 353, y: 178))
arrow.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
