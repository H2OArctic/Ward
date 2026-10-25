// Рисует иконку Ward и собирает AppIcon.icns.
//   swift tools/make-icon.swift            — иконка из варианта по умолчанию
//   swift tools/make-icon.swift ring       — конкретный вариант
//   swift tools/make-icon.swift --sheet    — лист сравнения всех вариантов в build/icon-variants.png
import AppKit

enum Variant: String, CaseIterable {
    case shield, ring, vault, key, light

    var title: String {
        switch self {
        case .shield: return "Щит"
        case .ring: return "Кольцо 2FA"
        case .vault: return "Сейф"
        case .key: return "Ключ"
        case .light: return "Кольцо, светлая"
        }
    }
}

let defaultVariant = Variant.key

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

let amber = [color(0xFFD796), color(0xF2B155), color(0xD98A2B)]

func fill(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGFloat, to: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: 512, y: from), end: CGPoint(x: 512, y: to), options: [])
    ctx.restoreGState()
}

func withShadow(_ ctx: CGContext, blur: CGFloat = 36, y: CGFloat = 18, alpha: CGFloat = 0.5, _ body: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: y), blur: blur, color: color(0x000000, alpha))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

/// Плашка по сетке системных иконок macOS: 824 × 824 с отступом 100.
func tile(_ ctx: CGContext, top: UInt32, bottom: UInt32, glow: CGFloat, rim: CGFloat) {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: rect, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.45))
    ctx.addPath(path)
    ctx.setFillColor(color(bottom))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(top), color(bottom)]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    if glow > 0 {
        ctx.drawRadialGradient(gradient([color(0xF2B155, glow), color(0xF2B155, 0)]),
                               startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 500), endRadius: 420, options: [])
    }
    ctx.restoreGState()

    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, rim))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func keyhole(center: CGPoint, scale s: CGFloat) -> CGPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: center.x + x * s, y: center.y + y * s) }
    let path = CGMutablePath()
    path.addEllipse(in: CGRect(x: center.x - 64 * s, y: center.y - 132 * s, width: 128 * s, height: 128 * s))
    path.move(to: p(-30, -32))
    path.addLine(to: p(30, -32))
    path.addLine(to: p(54, 114))
    path.addQuadCurve(to: p(36, 132), control: p(56, 132))
    path.addLine(to: p(-36, 132))
    path.addQuadCurve(to: p(-54, 114), control: p(-56, 132))
    path.closeSubpath()
    return path
}

func drawShield(_ ctx: CGContext) {
    tile(ctx, top: 0x33363E, bottom: 0x17181C, glow: 0.16, rim: 0.08)
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: 512, y: 232))
    shield.addCurve(to: CGPoint(x: 718, y: 318), control1: CGPoint(x: 584, y: 280), control2: CGPoint(x: 654, y: 308))
    shield.addCurve(to: CGPoint(x: 512, y: 812), control1: CGPoint(x: 718, y: 566), control2: CGPoint(x: 652, y: 736))
    shield.addCurve(to: CGPoint(x: 306, y: 318), control1: CGPoint(x: 372, y: 736), control2: CGPoint(x: 306, y: 566))
    shield.addCurve(to: CGPoint(x: 512, y: 232), control1: CGPoint(x: 370, y: 308), control2: CGPoint(x: 440, y: 280))
    shield.closeSubpath()
    withShadow(ctx) { fill(ctx, shield, amber, from: 232, to: 812) }
    ctx.saveGState()
    ctx.addPath(shield)
    ctx.clip()
    ctx.setFillColor(color(0xFFFFFF, 0.10))
    ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 1024))
    ctx.restoreGState()
    fill(ctx, keyhole(center: CGPoint(x: 512, y: 532), scale: 1), [color(0x121316), color(0x2A2D33)], from: 400, to: 664)
}

/// Кольцо обратного отсчёта, как у кодов 2FA в интерфейсе, вокруг замочной скважины.
func drawRing(_ ctx: CGContext, light: Bool) {
    if light {
        tile(ctx, top: 0xFBF8F2, bottom: 0xE6DFD2, glow: 0, rim: 0.5)
    } else {
        tile(ctx, top: 0x33363E, bottom: 0x17181C, glow: 0.12, rim: 0.08)
    }
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 262
    let width: CGFloat = 64

    let track = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    ctx.addPath(track)
    ctx.setFillColor(light ? color(0x1B1D21, 0.08) : color(0xFFFFFF, 0.08))
    ctx.fillPath()

    let arc = CGMutablePath()
    arc.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 1.5, clockwise: false)
    let arcShape = arc.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    withShadow(ctx, blur: 24, y: 10, alpha: light ? 0.18 : 0.45) {
        fill(ctx, arcShape, amber, from: 250, to: 774)
    }

    let hole = keyhole(center: CGPoint(x: 512, y: 512), scale: 1.05)
    if light {
        fill(ctx, hole, [color(0x2A2D33), color(0x121316)], from: 370, to: 650)
    } else {
        withShadow(ctx, blur: 24, y: 10, alpha: 0.45) { fill(ctx, hole, amber, from: 370, to: 650) }
    }
}

/// Дверь сейфа: диск с кремальерой и болтами по кругу.
func drawVault(_ ctx: CGContext) {
    tile(ctx, top: 0x33363E, bottom: 0x17181C, glow: 0.10, rim: 0.08)
    let c = CGPoint(x: 512, y: 512)
    func circle(_ r: CGFloat, _ at: CGPoint = CGPoint(x: 512, y: 512)) -> CGPath {
        CGPath(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2), transform: nil)
    }
    withShadow(ctx) { fill(ctx, circle(300), amber, from: 212, to: 812) }

    let groove = circle(236).copy(strokingWithWidth: 18, lineCap: .round, lineJoin: .round, miterLimit: 10)
    ctx.addPath(groove)
    ctx.setFillColor(color(0x7A4A12, 0.45))
    ctx.fillPath()

    for i in 0..<12 {
        let a = CGFloat(i) / 12 * .pi * 2
        ctx.addPath(circle(13, CGPoint(x: c.x + cos(a) * 270, y: c.y + sin(a) * 270)))
    }
    ctx.setFillColor(color(0x8A5516, 0.55))
    ctx.fillPath()

    let spokes = CGMutablePath()
    for i in 0..<3 {
        let a = CGFloat(i) / 3 * .pi + .pi / 6
        spokes.move(to: CGPoint(x: c.x + cos(a) * 170, y: c.y + sin(a) * 170))
        spokes.addLine(to: CGPoint(x: c.x - cos(a) * 170, y: c.y - sin(a) * 170))
    }
    let spokeShape = spokes.copy(strokingWithWidth: 38, lineCap: .round, lineJoin: .round, miterLimit: 10)
    fill(ctx, spokeShape, [color(0x2A2D33), color(0x121316)], from: 342, to: 682)
    for i in 0..<6 {
        let a = CGFloat(i) / 6 * .pi * 2 + .pi / 6
        fill(ctx, circle(30, CGPoint(x: c.x + cos(a) * 170, y: c.y + sin(a) * 170)),
             [color(0x2A2D33), color(0x121316)], from: 312, to: 712)
    }
    fill(ctx, circle(78), [color(0x2A2D33), color(0x121316)], from: 434, to: 590)
    ctx.addPath(circle(30))
    ctx.setFillColor(color(0xF2B155))
    ctx.fillPath()
}

/// Классический ключ по диагонали.
func drawKey(_ ctx: CGContext) {
    tile(ctx, top: 0x33363E, bottom: 0x17181C, glow: 0.12, rim: 0.08)
    let key = CGMutablePath()
    key.addEllipse(in: CGRect(x: 200, y: 382, width: 260, height: 260))
    key.addPath(CGPath(roundedRect: CGRect(x: 440, y: 480, width: 390, height: 64), cornerWidth: 20, cornerHeight: 20, transform: nil))
    key.addPath(CGPath(roundedRect: CGRect(x: 690, y: 520, width: 46, height: 104), cornerWidth: 12, cornerHeight: 12, transform: nil))
    key.addPath(CGPath(roundedRect: CGRect(x: 770, y: 520, width: 46, height: 76), cornerWidth: 12, cornerHeight: 12, transform: nil))

    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: -.pi / 4)
    ctx.translateBy(x: -512, y: -512)
    withShadow(ctx, blur: 30, y: 14, alpha: 0.5) {
        ctx.saveGState()
        // Детали перекрываются: сначала объединение по non-zero, затем отдельно вырезаем отверстие в кольце.
        ctx.addPath(key)
        ctx.clip()
        ctx.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        ctx.addEllipse(in: CGRect(x: 280, y: 462, width: 100, height: 100))
        ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(gradient(amber), start: CGPoint(x: 200, y: 382), end: CGPoint(x: 830, y: 640), options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

func draw(_ variant: Variant, in ctx: CGContext) {
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    switch variant {
    case .shield: drawShield(ctx)
    case .ring: drawRing(ctx, light: false)
    case .light: drawRing(ctx, light: true)
    case .vault: drawVault(ctx)
    case .key: drawKey(ctx)
    }
}

func bitmap(_ size: Int, _ body: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    body(ctx)
    return rep
}

func png(_ variant: Variant, size: Int) -> Data {
    bitmap(size) { ctx in
        ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        draw(variant, in: ctx)
    }.representation(using: .png, properties: [:])!
}

func sheet() -> Data {
    let cell: CGFloat = 340, big: CGFloat = 280, pad: CGFloat = 30
    let variants = Variant.allCases
    let width = Int(CGFloat(variants.count) * cell + pad)
    let height = 470
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setFillColor(color(0x5A5F6A))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (i, variant) in variants.enumerated() {
        let x = pad + CGFloat(i) * cell
        for (size, origin) in [(big, CGPoint(x: x, y: 150)), (64, CGPoint(x: x + 40, y: 60)), (32, CGPoint(x: x + 130, y: 76)), (16, CGPoint(x: x + 190, y: 84))] {
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.scaleBy(x: size / 1024, y: size / 1024)
            draw(variant, in: ctx)
            ctx.restoreGState()
        }
        let label = "\(i + 1). \(variant.title)" as NSString
        label.draw(at: CGPoint(x: x + 20, y: 20), withAttributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let build = root.appendingPathComponent("build")
try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
let argument = CommandLine.arguments.dropFirst().first

if argument == "--sheet" {
    try sheet().write(to: build.appendingPathComponent("icon-variants.png"))
    print("build/icon-variants.png готов")
    exit(0)
}

guard let variant = argument.map({ Variant(rawValue: $0) }) ?? defaultVariant else {
    print("Неизвестный вариант. Есть: \(Variant.allCases.map(\.rawValue).joined(separator: ", "))")
    exit(1)
}

let iconset = build.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(variant, size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(variant, size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(variant, size: 1024).write(to: build.appendingPathComponent("AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "AppIcon.icns готов (\(variant.rawValue))" : "iconutil упал: \(iconutil.terminationStatus)")
