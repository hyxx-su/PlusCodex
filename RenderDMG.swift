import AppKit

// Vector-drawn installation artwork; the app and folder remain real Finder icons.
let image = NSImage(size: NSSize(width: 720, height: 460))
image.lockFocus()
NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 720, height: 460).fill()
func label(_ value: String, _ rect: NSRect, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ gray: CGFloat = 0.15) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(calibratedWhite: gray, alpha: 1), .paragraphStyle: paragraph])
}
label("A LITTLE PLUS FOR YOUR DAY", NSRect(x: 0, y: 402, width: 720, height: 18), 10, .semibold, 0.5)
label("Hello, PlusCodex.", NSRect(x: 0, y: 350, width: 720, height: 48), 34, .bold)
label("작은 플러스, 더 편한 Codex 생활", NSRect(x: 0, y: 321, width: 720, height: 24), 14, .regular, 0.45)
for x: CGFloat in [92, 438] {
    NSColor.white.setFill()
    let card = NSBezierPath(roundedRect: NSRect(x: x, y: 100, width: 190, height: 190), xRadius: 30, yRadius: 30)
    card.fill()
    NSColor(calibratedWhite: 0.9, alpha: 1).setStroke()
    card.lineWidth = 1
    card.stroke()
}
// Tiny friendly guide between the two actual draggable icons.
NSColor(calibratedWhite: 0.3, alpha: 1).setFill()
for x: CGFloat in [347, 369] { NSBezierPath(ovalIn: NSRect(x: x, y: 231, width: 4, height: 6)).fill() }
NSColor(calibratedWhite: 0.3, alpha: 1).setStroke()
let smile = NSBezierPath()
smile.move(to: NSPoint(x: 349, y: 220))
smile.curve(to: NSPoint(x: 371, y: 220), controlPoint1: NSPoint(x: 354, y: 212), controlPoint2: NSPoint(x: 366, y: 212))
smile.lineWidth = 2
smile.stroke()
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 318, y: 185)); arrow.line(to: NSPoint(x: 400, y: 185))
arrow.move(to: NSPoint(x: 389, y: 196)); arrow.line(to: NSPoint(x: 400, y: 185)); arrow.line(to: NSPoint(x: 389, y: 174))
arrow.lineWidth = 2
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.stroke()
label("이쪽으로 쏙", NSRect(x: 296, y: 141, width: 128, height: 22), 12, .medium, 0.5)
label("앱을 Applications 폴더로 드래그해 주세요", NSRect(x: 0, y: 55, width: 720, height: 24), 14, .medium)
label("복사 후 응용 프로그램에서 실행하면, 메뉴바에서 만나요.", NSRect(x: 0, y: 28, width: 720, height: 20), 11, .regular, 0.5)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
