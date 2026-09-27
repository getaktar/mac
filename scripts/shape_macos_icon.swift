// Fits full-bleed square artwork onto Apple's macOS app icon grid: a 1024px
// transparent canvas with an 824px continuous-corner rounded rectangle
// ("squircle") body and a soft drop shadow. macOS does not mask app icons
// itself, and recent versions put icons that don't follow this shape inside
// a grey plate, so the shape has to be baked into the PNG.
//
// Usage: swift scripts/shape_macos_icon.swift <square-artwork.png> <output.png>
import AppKit
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("Usage: swift scripts/shape_macos_icon.swift <input.png> <output.png>\n".data(using: .utf8)!)
    exit(1)
}

guard let source = NSImage(contentsOfFile: arguments[1]),
      let artwork = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("Could not read \(arguments[1])\n".data(using: .utf8)!)
    exit(1)
}

// Apple's macOS icon template (Big Sur and later): 1024 canvas, 824 body
// inset by 100 on each side, 185.4 continuous corner radius.
let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: body).cgPath

guard let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
context.interpolationQuality = .high

// Drop shadow, drawn from a filled copy of the shape so it sits outside the body.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: NSColor.black.withAlphaComponent(0.3).cgColor)
context.addPath(shape)
context.setFillColor(NSColor.black.cgColor)
context.fillPath()
context.restoreGState()

// The artwork, scaled down into the body and clipped to its shape.
context.saveGState()
context.addPath(shape)
context.clip()
context.draw(artwork, in: body)
context.restoreGState()

guard let image = context.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
do {
    try data.write(to: URL(fileURLWithPath: arguments[2]))
} catch {
    FileHandle.standardError.write("Could not write \(arguments[2]): \(error)\n".data(using: .utf8)!)
    exit(1)
}
