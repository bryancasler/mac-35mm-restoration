// Renders the FilmRestore app icon (vertical film strip + sparkle) to PNG.
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

extension CGContext {
    func fill(_ rect: CGRect, cornerRadius: CGFloat) {
        addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                       cornerHeight: cornerRadius, transform: nil))
        fillPath()
    }
}

// vertical film strip: dark band running top-to-bottom like film in a projector
ctx.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 0.9).cgColor)
ctx.fill(CGRect(x: 330, y: 60, width: 364, height: 904))
// sprocket holes: left + right columns
ctx.setFillColor(NSColor(calibratedWhite: 0.95, alpha: 0.95).cgColor)
for i in 0..<7 {
    let y = 108 + CGFloat(i) * 130
    ctx.fill(CGRect(x: 358, y: y, width: 44, height: 62), cornerRadius: 10)
    ctx.fill(CGRect(x: 622, y: y, width: 44, height: 62), cornerRadius: 10)
}
// two frames stacked vertically inside the strip
ctx.setFillColor(NSColor(calibratedRed: 0.98, green: 0.85, blue: 0.55, alpha: 1).cgColor)
ctx.fill(CGRect(x: 428, y: 544, width: 168, height: 350), cornerRadius: 16)
ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.82, alpha: 1).cgColor)
ctx.fill(CGRect(x: 428, y: 130, width: 168, height: 350), cornerRadius: 16)

// scratch on the top frame (the "before")
ctx.setStrokeColor(NSColor(calibratedWhite: 0.25, alpha: 0.8).cgColor)
ctx.setLineWidth(7)
ctx.move(to: CGPoint(x: 495, y: 886))
ctx.addLine(to: CGPoint(x: 508, y: 552))
ctx.strokePath()

// sparkle on the bottom frame (the "after")
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
star(center: CGPoint(x: 512, y: 300), r: 64)
star(center: CGPoint(x: 458, y: 218), r: 30)

image.unlockFocus()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
