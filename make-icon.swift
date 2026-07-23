import AppKit

// Turn a full-bleed square PNG into a macOS-style icon master: the artwork
// clipped to Apple's rounded-rect grid (824/1024), centred with padding, plus a
// soft drop shadow. Output: a 1024x1024 PNG.
// Usage: swift make-icon.swift <input.png> <output.png>

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: make-icon.swift <in.png> <out.png>\n".data(using: .utf8)!)
    exit(1)
}

let canvas = 1024.0
let body = 824.0                 // Apple's macOS icon body size within 1024
let inset = (canvas - body) / 2  // 100pt padding each side
let radius = body * 0.2237       // continuous-corner radius for the body

let out = NSImage(size: NSSize(width: canvas, height: canvas))
out.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

let bodyRect = CGRect(x: inset, y: inset, width: body, height: body)
let path = CGPath(roundedRect: bodyRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Soft drop shadow beneath the icon body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10),
              blur: 24,
              color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Clip to the rounded body and draw the artwork to fill it.
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
src.draw(in: bodyRect, from: .zero, operation: .copy, fraction: 1.0)
ctx.restoreGState()

out.unlockFocus()

guard let tiff = out.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
