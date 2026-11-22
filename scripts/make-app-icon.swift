// Draws the app icon: three cream comic panels on a blue page, with a speech balloon in the
// top panel. Two colours, opaque, 1024×1024.
// Usage: swift scripts/make-app-icon.swift Comics/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png")

let blue = CGColor(srgbRed: 0.13, green: 0.30, blue: 0.55, alpha: 1)
let cream = CGColor(srgbRed: 0.98, green: 0.95, blue: 0.88, alpha: 1)

guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("no context") }
// CoreGraphics' origin is bottom-left; flip so the layout below reads top-down.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

ctx.setFillColor(blue)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

let margin: CGFloat = 176
let gutter: CGFloat = 44
let radius: CGFloat = 28
let inner = CGFloat(size) - 2 * margin
let topHeight: CGFloat = 330
let bottomHeight = inner - topHeight - gutter
let half = (inner - gutter) / 2

func panel(_ rect: CGRect) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(cream)
    ctx.fillPath()
}

let top = CGRect(x: margin, y: margin, width: inner, height: topHeight)
panel(top)
panel(CGRect(x: margin, y: margin + topHeight + gutter, width: half, height: bottomHeight))
panel(CGRect(x: margin + half + gutter, y: margin + topHeight + gutter, width: half, height: bottomHeight))

// Speech balloon in the top panel: an ellipse with a tail pointing down-left.
let balloon = CGRect(x: top.midX - 150, y: top.minY + 62, width: 300, height: 170)
ctx.setFillColor(blue)
ctx.fillEllipse(in: balloon)
ctx.move(to: CGPoint(x: balloon.minX + 90, y: balloon.maxY - 30))
ctx.addLine(to: CGPoint(x: balloon.minX + 40, y: balloon.maxY + 48))
ctx.addLine(to: CGPoint(x: balloon.minX + 150, y: balloon.maxY - 20))
ctx.closePath()
ctx.fillPath()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("no image") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote \(out.path)")
