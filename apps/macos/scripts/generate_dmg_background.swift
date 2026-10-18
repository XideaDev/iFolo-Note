import AppKit

// Target Dimensions (Retina @2x)
let widthPt: CGFloat = 640
let heightPt: CGFloat = 420
let scale: CGFloat = 2.0
let widthPx = Int(widthPt * scale)
let heightPx = Int(heightPt * scale)

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputURL = rootURL.appendingPathComponent("apps/macos/Resources/dmg/background.png")

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: widthPx,
    pixelsHigh: heightPx,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
rep.size = NSSize(width: widthPt, height: heightPt)

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx

let bounds = NSRect(x: 0, y: 0, width: widthPt, height: heightPt)

// --- A. Draw elegant Apple Liquid Glass gradient base ---
let gradient = NSGradient(
    colors: [
        NSColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1.0), // #F5F7FC
        NSColor(red: 0.92, green: 0.94, blue: 0.97, alpha: 1.0)  // #EBF0F7
    ]
)!
gradient.draw(in: bounds, angle: -90.0)

// Subtle decorative top accent glow (Sky blue mesh)
let glowPath = NSBezierPath(ovalIn: NSRect(x: 120, y: heightPt - 160, width: 400, height: 240))
let glowGradient = NSGradient(
    colors: [
        NSColor(red: 0.05, green: 0.65, blue: 0.95, alpha: 0.09),
        NSColor(red: 0.05, green: 0.65, blue: 0.95, alpha: 0.0)
    ]
)!
glowGradient.draw(in: glowPath, relativeCenterPosition: .zero)

// Outer rounded frame & border
let innerFrame = bounds.insetBy(dx: 12, dy: 12)
let framePath = NSBezierPath(roundedRect: innerFrame, xRadius: 14, yRadius: 14)
NSColor(red: 0.82, green: 0.86, blue: 0.92, alpha: 0.65).setStroke()
framePath.lineWidth = 1.0
framePath.stroke()

// --- B. Top Header (Brand Typography) ---
let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
let titleStyle = NSMutableParagraphStyle()
titleStyle.alignment = .center

let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: titleFont,
    .foregroundColor: NSColor(red: 0.09, green: 0.12, blue: 0.17, alpha: 1.0), // Slate 900
    .paragraphStyle: titleStyle,
    .kern: 0.6
]
let titleStr = NSAttributedString(string: "iFolo Note · 心流笔记", attributes: titleAttrs)
titleStr.draw(in: NSRect(x: 0, y: heightPt - 66, width: widthPt, height: 30))

let subFont = NSFont.systemFont(ofSize: 12.5, weight: .regular)
let subStyle = NSMutableParagraphStyle()
subStyle.alignment = .center

let subAttrs: [NSAttributedString.Key: Any] = [
    .font: subFont,
    .foregroundColor: NSColor(red: 0.38, green: 0.44, blue: 0.52, alpha: 1.0), // Slate 500
    .paragraphStyle: subStyle,
    .kern: 0.3
]
let subStr = NSAttributedString(string: "轻量 · 极速 · 悬浮不夺焦 · 屏幕边缘触手可及", attributes: subAttrs)
subStr.draw(in: NSRect(x: 0, y: heightPt - 90, width: widthPt, height: 20))

// --- C. Pedestals (Card Drop Zones) ---
let leftCenter = NSPoint(x: 160, y: 230)
let rightCenter = NSPoint(x: 480, y: 230)
let cardSize = NSSize(width: 148, height: 156)

func drawCard(at center: NSPoint) {
    let cardRect = NSRect(
        x: center.x - cardSize.width / 2,
        y: center.y - cardSize.height / 2,
        width: cardSize.width,
        height: cardSize.height
    )
    
    // Soft shadow under pedestal
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(red: 0.09, green: 0.15, blue: 0.28, alpha: 0.07)
    shadow.shadowOffset = NSSize(width: 0, height: -3)
    shadow.shadowBlurRadius = 10
    
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    
    let path = NSBezierPath(roundedRect: cardRect, xRadius: 22, yRadius: 22)
    NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.88).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    
    NSColor(red: 0.86, green: 0.89, blue: 0.94, alpha: 0.95).setStroke()
    path.lineWidth = 1.2
    path.stroke()

    let innerRect = cardRect.insetBy(dx: 6, dy: 6)
    let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: 18, yRadius: 18)
    let pattern: [CGFloat] = [4, 4]
    innerPath.setLineDash(pattern, count: 2, phase: 0)
    NSColor(red: 0.14, green: 0.60, blue: 0.92, alpha: 0.38).setStroke()
    innerPath.lineWidth = 1.0
    innerPath.stroke()
}

drawCard(at: leftCenter)
drawCard(at: rightCenter)

// --- D. Directional Arrow & Action Pill in Center ---
let iconCenterY: CGFloat = 240
let arrowStartX: CGFloat = leftCenter.x + cardSize.width / 2 + 14 // 160 + 74 + 14 = 248
let arrowEndX: CGFloat = rightCenter.x - cardSize.width / 2 - 14   // 480 - 74 - 14 = 392

let pillWidth: CGFloat = 168
let pillHeight: CGFloat = 26
let pillRect = NSRect(x: (widthPt - pillWidth) / 2, y: iconCenterY + 14, width: pillWidth, height: pillHeight)

let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 13, yRadius: 13)
NSColor(red: 0.92, green: 0.96, blue: 1.0, alpha: 0.95).setFill()
pillPath.fill()
NSColor(red: 0.14, green: 0.60, blue: 0.92, alpha: 0.45).setStroke()
pillPath.lineWidth = 1.0
pillPath.stroke()

let pillStyle = NSMutableParagraphStyle()
pillStyle.alignment = .center
let pillAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
    .foregroundColor: NSColor(red: 0.05, green: 0.45, blue: 0.82, alpha: 1.0),
    .paragraphStyle: pillStyle
]
let pillText = NSAttributedString(string: "拖拽至 Applications 完成安装", attributes: pillAttrs)
pillText.draw(in: NSRect(x: pillRect.minX, y: pillRect.minY + 5, width: pillWidth, height: 16))

let arrowPath = NSBezierPath()
arrowPath.move(to: NSPoint(x: arrowStartX, y: iconCenterY - 4))
arrowPath.line(to: NSPoint(x: arrowEndX, y: iconCenterY - 4))
arrowPath.lineWidth = 2.4
NSColor(red: 0.14, green: 0.60, blue: 0.92, alpha: 0.85).setStroke()
arrowPath.stroke()

let headPath = NSBezierPath()
let headTip = NSPoint(x: arrowEndX + 3, y: iconCenterY - 4)
headPath.move(to: headTip)
headPath.line(to: NSPoint(x: arrowEndX - 10, y: iconCenterY + 3.5))
headPath.line(to: NSPoint(x: arrowEndX - 10, y: iconCenterY - 11.5))
headPath.close()
NSColor(red: 0.14, green: 0.60, blue: 0.92, alpha: 0.85).setFill()
headPath.fill()

// --- E. Bottom Footer ---
let footerY: CGFloat = 42
let footerFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)

let footerLeftAttrs: [NSAttributedString.Key: Any] = [
    .font: footerFont,
    .foregroundColor: NSColor(red: 0.45, green: 0.52, blue: 0.62, alpha: 1.0)
]
let fLeft = NSAttributedString(string: "⌘ 原生 Swift 5 · 零运行时依赖 · macOS 14.0+", attributes: footerLeftAttrs)
fLeft.draw(at: NSPoint(x: 34, y: footerY))

let footerRightStyle = NSMutableParagraphStyle()
footerRightStyle.alignment = .right
let footerRightAttrs: [NSAttributedString.Key: Any] = [
    .font: footerFont,
    .foregroundColor: NSColor(red: 0.45, green: 0.52, blue: 0.62, alpha: 1.0),
    .paragraphStyle: footerRightStyle
]
let fRight = NSAttributedString(string: "纯文本 Markdown · 本地语义检索 · MIT 协议", attributes: footerRightAttrs)
fRight.draw(in: NSRect(x: widthPt - 340, y: footerY, width: 306, height: 16))

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    print("Failed to encode PNG")
    exit(1)
}

try data.write(to: outputURL)
print("Saved elegant iFolo DMG background to", outputURL.path)
