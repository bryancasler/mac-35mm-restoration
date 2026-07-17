// Renders the FilmRestore app icon (film strip + sparkle) to icon_1024.png.
// Run: swift make-icon.swift <output.png>
import AppKit

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext

// rounded-square background, deep amber-to-brown (film base color)
let bg = CGPath(roundedRect: CGRect(x: 60, y: 60, width: 904, height: 904),
                cornerWidth: 200, cornerHeight: 200, transform: nil)
ctx.addPath(bg)
ctx.clip()
let colors = [NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.18, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.35, green: 0.16, blue: 0.05, alpha: 1).cgColor]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 964),
                       end: CGPoint(x: 824, y: 60), options: [])

// film strip: dark band with sprocket holes
ctx.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 0.9).cgColor)
ctx.fill(CGRect(x: 60, y: 330, width: 904, height: 364))
ctx.setFillColor(NSColor(calibratedWhite: 0.95, alpha: 0.95).cgColor)
for i in 0..<7 {
    let x = 108 + CGFloat(i) * 130
    ctx.fill(CGRect(x: x, y: 358, width: 62, height: 44), cornerRadius: 10)
    ctx.fill(CGRect(x: x, y: 622, width: 62, height: 44), cornerRadius: 10)
}
// two frames inside the strip
ctx.setFillColor(NSColor(calibratedRed: 0.98, green: 0.85, blue: 0.55, alpha: 1).cgColor)
ctx.fill(CGRect(x: 130, y: 428, width: 350, height: 168), cornerRadius: 16)
ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.82, alpha: 1).cgColor)
ctx.fill(CGRect(x: 544, y: 428, width: 350, height: 168), cornerRadius: 16)

// scratch on left frame (the "before")
ctx.setStrokeColor(NSColor(calibratedWhite: 0.25, alpha: 0.8).cgColor)
ctx.setLineWidth(7)
ctx.move(to: CGPoint(x: 240, y: 436))
ctx.addLine(to: CGPoint(x: 255, y: 588))
ctx.strokePath()

// sparkle on right frame (the "after")
func star(center: CGPoint, r: CGFloat) {
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.move(to: CGPoint(x: center.x, y: center.y + r))
    ctx.addQuadCurve(to: CGPoint(x: center.x + r, y: center.y),
                     control: CGPoint(x: center.x + r * 0.18, y: center.y + r * 0.18))
    ctx.addQuadCurve(to: CGPoint(x: center.x, y: center.y - r),
                     control: CGPoint(x: center.x + r * 0.18, y: center.y - r * 0.18))
    ctx.addQuadCurve(to: CGPoint(x: center.x - r, y: center.y),
                     control: CGPoint(x: center.x - r * 0.18, y: center.y - r * 0.18))
    ctx.addQuadCurve(to: CGPoint(x: center.x, y: center.y + r),
                     control: CGPoint(x: center.x - r * 0.18, y: center.y + r * 0.18))
    ctx.fillPath()
}
star(center: CGPoint(x: 780, y: 540), r: 68)
star(center: CGPoint(x: 690, y: 470), r: 34)

image.unlockFocus()

extension CGContext {
    func fill(_ rect: CGRect, cornerRadius: CGFloat) {
        addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                       cornerHeight: cornerRadius, transform: nil))
        fillPath()
    }
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
