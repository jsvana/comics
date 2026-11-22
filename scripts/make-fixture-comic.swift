// Regenerates Comics/Resources/Fixtures, the offline comic used by UI and reader tests.
// Usage: swift scripts/make-fixture-comic.swift Comics/Resources/Fixtures
//
// Twelve numbered strips. Most are 800x1135 portrait PNGs with the number drawn large;
// strip 5 is a tall 600x3000 strip; strip 7's page has no image (a "couldn't load" strip);
// strip 3 has a bonus image.
import AppKit
import CoreGraphics
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Comics/Resources/Fixtures")
let strips = out.appendingPathComponent("strips")
try FileManager.default.createDirectory(at: strips, withIntermediateDirectories: true)

func png(width: Int, height: Int, hue: CGFloat, label: String, panels: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let paper = NSColor(calibratedHue: hue, saturation: 0.12, brightness: 0.98, alpha: 1).cgColor
    let ink = NSColor(calibratedHue: hue, saturation: 0.6, brightness: 0.35, alpha: 1).cgColor
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // Panels stacked top to bottom, each with a border.
    let margin: CGFloat = 24
    let gap: CGFloat = 18
    let panelHeight = (CGFloat(height) - 2 * margin - CGFloat(panels - 1) * gap) / CGFloat(panels)
    for i in 0..<panels {
        let y = CGFloat(height) - margin - CGFloat(i + 1) * panelHeight - CGFloat(i) * gap
        let rect = CGRect(x: margin, y: y, width: CGFloat(width) - 2 * margin, height: panelHeight)
        ctx.setFillColor(paper)
        ctx.fill(rect)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(5)
        ctx.stroke(rect)
    }
    // The label, centred in the first panel.
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = gc
    let size = min(CGFloat(width) * 0.45, panelHeight * 0.6)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .heavy),
        .foregroundColor: NSColor(cgColor: ink)!,
    ]
    let text = NSAttributedString(string: label, attributes: attrs)
    let bounds = text.size()
    let top = CGFloat(height) - margin - panelHeight
    text.draw(at: CGPoint(x: (CGFloat(width) - bounds.width) / 2, y: top + (panelHeight - bounds.height) / 2))
    NSGraphicsContext.current = nil
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let hovers: [Int: String] = [
    1: "The first strip.",
    2: "A longer piece of hover text, the kind that runs on for a while and has to wrap onto a second or even a third line under the strip.",
    3: "This one has a bonus panel below.",
    5: "A tall strip: keep scrolling.",
]

for n in 1...12 {
    let hue = CGFloat(n) / 12
    if n == 7 {
        try "<html><body><h1>Fixture 7</h1><p>This page has no strip.</p></body></html>\n"
            .write(to: strips.appendingPathComponent("7.html"), atomically: true, encoding: .utf8)
        continue
    }
    let tall = n == 5
    try png(width: tall ? 600 : 800, height: tall ? 3000 : 1135, hue: hue, label: "\(n)", panels: tall ? 6 : 3,
            to: strips.appendingPathComponent("\(n).png"))
    var html = "<html><body><h1>Fixture \(n)</h1>\n"
    html += "<img id=\"strip\" src=\"\(n).png\" title=\"\(hovers[n] ?? "Hover text for strip \(n).")\">\n"
    if n == 3 {
        try png(width: 800, height: 360, hue: 0.1, label: "bonus", panels: 1, to: strips.appendingPathComponent("3-bonus.png"))
        html += "<img id=\"bonus\" src=\"3-bonus.png\">\n"
    }
    html += "</body></html>\n"
    try html.write(to: strips.appendingPathComponent("\(n).html"), atomically: true, encoding: .utf8)
}
try "12\n".write(to: out.appendingPathComponent("latest.txt"), atomically: true, encoding: .utf8)
print("wrote \(out.path)")
