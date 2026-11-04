// Renders Resources/AppIcon.icns:  swift tools/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 body with ~185/1024 corner radius
    let inset = s * 100 / 1024, body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSShadow().then { $0.shadowColor = NSColor.black.withAlphaComponent(0.35); $0.shadowBlurRadius = s * 0.02
                      $0.shadowOffset = NSSize(width: 0, height: -s * 0.01); $0.set() }
    NSGradient(starting: NSColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 1),
               ending: NSColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1))!.draw(in: path, angle: -90)
    NSShadow().set()
    // status-bar strip with a green NORMAL pill
    let bar = NSRect(x: body.minX, y: body.minY + body.height * 0.12, width: body.width, height: body.height * 0.11)
    NSGraphicsContext.current!.saveGraphicsState(); path.addClip()
    NSColor(white: 1, alpha: 0.07).setFill(); bar.fill()
    NSGraphicsContext.current!.restoreGraphicsState()
    let pill = NSRect(x: body.minX + body.width * 0.09, y: bar.minY + bar.height * 0.22, width: body.width * 0.24, height: bar.height * 0.56)
    NSColor(red: 0.42, green: 0.80, blue: 0.47, alpha: 1).setFill()
    NSBezierPath(roundedRect: pill, xRadius: pill.height * 0.3, yRadius: pill.height * 0.3).fill()
    // "vi" with a block cursor
    let font = NSFont.monospacedSystemFont(ofSize: s * 0.28, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.95, alpha: 1)]
    let text = "vi" as NSString, ts = text.size(withAttributes: attrs)
    let charW = ts.width / 2
    let tx = body.midX - (ts.width + charW * 0.9) / 2, ty = body.midY - ts.height / 2 + body.height * 0.06
    text.draw(at: NSPoint(x: tx, y: ty), withAttributes: attrs)
    NSColor(red: 0.98, green: 0.76, blue: 0.35, alpha: 1).setFill()
    NSRect(x: tx + ts.width + charW * 0.15, y: ty + ts.height * 0.18, width: charW * 0.75, height: ts.height * 0.62).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
extension NSObject { @discardableResult func then(_ f: (Self) -> Void) -> Self { f(self); return self } }

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
