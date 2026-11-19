import AppKit

// 앱 아이콘 생성: swift Tools/make-icon.swift <출력 .appiconset 폴더>
// 파란 둥근 사각형 + 흰 편지봉투 + 노란 "가" 배지 (Apple 아이콘을 쓰지 않고 직접 그린다)

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // 바탕: macOS 아이콘 격자(824pt 둥근 사각형)
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSGradient(starting: NSColor(red: 0.33, green: 0.67, blue: 1.00, alpha: 1),
               ending: NSColor(red: 0.07, green: 0.38, blue: 0.93, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185), angle: -90)
    ctx.restoreGState()

    // 편지봉투
    let envelope = CGRect(x: 222, y: 300, width: 580, height: 410)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.2).cgColor)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: envelope, xRadius: 44, yRadius: 44).fill()
    ctx.restoreGState()

    let fold = NSBezierPath()
    fold.move(to: CGPoint(x: envelope.minX + 30, y: envelope.maxY - 30))
    fold.line(to: CGPoint(x: envelope.midX, y: envelope.midY - 20))
    fold.line(to: CGPoint(x: envelope.maxX - 30, y: envelope.maxY - 30))
    fold.lineWidth = 26
    fold.lineCapStyle = .round
    fold.lineJoinStyle = .round
    NSColor(red: 0.07, green: 0.38, blue: 0.93, alpha: 0.85).setStroke()
    fold.stroke()

    // "가" 배지
    let badge = CGRect(x: 549, y: 161, width: 300, height: 300)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSGradient(starting: NSColor(red: 1.00, green: 0.86, blue: 0.25, alpha: 1),
               ending: NSColor(red: 1.00, green: 0.72, blue: 0.00, alpha: 1))!.draw(in: NSBezierPath(ovalIn: badge), angle: -90)
    ctx.restoreGState()
    NSColor.white.setStroke()
    let ring = NSBezierPath(ovalIn: badge.insetBy(dx: 7, dy: 7))
    ring.lineWidth = 14
    ring.stroke()

    let font = NSFont(name: "AppleSDGothicNeo-Heavy", size: 170) ?? NSFont.systemFont(ofSize: 170, weight: .heavy)
    let text = NSAttributedString(string: "가", attributes: [.font: font, .foregroundColor: NSColor(red: 0.30, green: 0.20, blue: 0.00, alpha: 1)])
    let textSize = text.size()
    text.draw(at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2 + 6))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let file = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(CGFloat(points * scale)).write(to: output.appendingPathComponent(file))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": file])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("생성: \(output.path)")
