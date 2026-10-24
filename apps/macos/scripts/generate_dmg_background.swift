import AppKit

// Target Dimensions (Retina @2x: 640 x 420 pt -> 1280 x 840 px)
let widthPt: CGFloat = 640
let heightPt: CGFloat = 420
let scale: CGFloat = 2.0
let widthPx = Int(widthPt * scale)
let heightPx = Int(heightPt * scale)

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let baseTextureURL = rootURL.appendingPathComponent("apps/macos/Resources/dmg/paper_texture.png")
let outputURL = rootURL.appendingPathComponent("apps/macos/Resources/dmg/background.png")

guard let baseImage = NSImage(contentsOf: baseTextureURL) else {
    print("❌ 无法加载基底纸质纹理: \(baseTextureURL.path)")
    exit(1)
}

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

// --- A. 绘制复古纸质纹理基底 ---
baseImage.draw(in: bounds)

// 针对图标落点区域贴合干净纯粹的纸质纹理修补
let cleanTop = NSRect(x: 20, y: 620, width: 490, height: 160)
let cleanBottom = NSRect(x: 20, y: 20, width: 490, height: 160)
baseImage.draw(in: NSRect(x: 20, y: 70, width: 280, height: 280), from: cleanBottom, operation: .sourceOver, fraction: 1.0)
baseImage.draw(in: NSRect(x: 340, y: 70, width: 280, height: 280), from: cleanTop, operation: .sourceOver, fraction: 1.0)
baseImage.draw(in: NSRect(x: 200, y: 140, width: 240, height: 140), from: cleanBottom, operation: .sourceOver, fraction: 1.0)

// 精致复古纸边画框内边线
let innerFrame = bounds.insetBy(dx: 14, dy: 14)
let framePath = NSBezierPath(roundedRect: innerFrame, xRadius: 12, yRadius: 12)
NSColor(white: 0.2, alpha: 0.04).setStroke()
framePath.lineWidth = 1.0
framePath.stroke()

// --- B. 顶部品牌字阶与产品定位 ---
let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
let titleStyle = NSMutableParagraphStyle()
titleStyle.alignment = .center

let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: titleFont,
    .foregroundColor: NSColor(red: 0.14, green: 0.13, blue: 0.12, alpha: 1.0),
    .paragraphStyle: titleStyle,
    .kern: 0.8
]
let titleStr = NSAttributedString(string: "iFolo Note", attributes: titleAttrs)
titleStr.draw(in: NSRect(x: 0, y: heightPt - 68, width: widthPt, height: 30))

let subFont = NSFont.systemFont(ofSize: 12.5, weight: .regular)
let subStyle = NSMutableParagraphStyle()
subStyle.alignment = .center

let subAttrs: [NSAttributedString.Key: Any] = [
    .font: subFont,
    .foregroundColor: NSColor(red: 0.44, green: 0.42, blue: 0.39, alpha: 1.0),
    .paragraphStyle: subStyle,
    .kern: 0.3
]
let subStr = NSAttributedString(string: "macOS 原生极速贴边悬浮笔记 · 心流触手可及", attributes: subAttrs)
subStr.draw(in: NSRect(x: 0, y: heightPt - 92, width: widthPt, height: 20))

// --- C. 卡片底座 (Pedestals / Card Drop Zones) ---
// 左侧 (iFolo.app: 160, 230), 右侧 (Applications: 480, 230)
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
    
    // 柔和微弱阴影
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.05)
    shadow.shadowOffset = NSSize(width: 0, height: -3)
    shadow.shadowBlurRadius = 8
    
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    
    let path = NSBezierPath(roundedRect: cardRect, xRadius: 22, yRadius: 22)
    NSColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 0.78).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    
    NSColor(red: 0.85, green: 0.82, blue: 0.77, alpha: 0.8).setStroke()
    path.lineWidth = 1.2
    path.stroke()

    // 内部虚线装饰框
    let innerRect = cardRect.insetBy(dx: 6, dy: 6)
    let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: 18, yRadius: 18)
    let pattern: [CGFloat] = [4, 4]
    innerPath.setLineDash(pattern, count: 2, phase: 0)
    NSColor(red: 0.88, green: 0.85, blue: 0.81, alpha: 0.55).setStroke()
    innerPath.lineWidth = 1.0
    innerPath.stroke()
}

drawCard(at: leftCenter)
drawCard(at: rightCenter)

// --- D. 中央动作引导胶囊与箭头 ---
// 图标中心在 Cocoa y = 240
let iconCenterY: CGFloat = 240
let arrowStartX: CGFloat = leftCenter.x + cardSize.width / 2 + 14 // 160 + 74 + 14 = 248
let arrowEndX: CGFloat = rightCenter.x - cardSize.width / 2 - 14   // 480 - 74 - 14 = 392

// 动作胶囊背景
let pillWidth: CGFloat = 144
let pillHeight: CGFloat = 24
let pillRect = NSRect(x: (widthPt - pillWidth) / 2, y: iconCenterY + 16, width: pillWidth, height: pillHeight)

let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 12, yRadius: 12)
NSColor(red: 0.93, green: 0.91, blue: 0.87, alpha: 0.92).setFill()
pillPath.fill()
NSColor(red: 0.82, green: 0.79, blue: 0.74, alpha: 0.85).setStroke()
pillPath.lineWidth = 1.0
pillPath.stroke()

let pillStyle = NSMutableParagraphStyle()
pillStyle.alignment = .center
let pillAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
    .foregroundColor: NSColor(red: 0.28, green: 0.26, blue: 0.24, alpha: 1.0),
    .paragraphStyle: pillStyle
]
let pillText = NSAttributedString(string: "拖拽至此处完成安装", attributes: pillAttrs)
pillText.draw(in: NSRect(x: pillRect.minX, y: pillRect.minY + 4, width: pillWidth, height: 16))

// 向右导向箭头
let arrowPath = NSBezierPath()
arrowPath.move(to: NSPoint(x: arrowStartX, y: iconCenterY - 4))
arrowPath.line(to: NSPoint(x: arrowEndX, y: iconCenterY - 4))
arrowPath.lineWidth = 2.2
NSColor(red: 0.35, green: 0.33, blue: 0.30, alpha: 0.75).setStroke()
arrowPath.stroke()

let headPath = NSBezierPath()
let headTip = NSPoint(x: arrowEndX + 2, y: iconCenterY - 4)
headPath.move(to: headTip)
headPath.line(to: NSPoint(x: arrowEndX - 10, y: iconCenterY + 3))
headPath.line(to: NSPoint(x: arrowEndX - 10, y: iconCenterY - 11))
headPath.close()
NSColor(red: 0.35, green: 0.33, blue: 0.30, alpha: 0.75).setFill()
headPath.fill()

// --- E. 底部页脚技术信息 ---
let footerY: CGFloat = 46
let footerFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)

let footerLeftAttrs: [NSAttributedString.Key: Any] = [
    .font: footerFont,
    .foregroundColor: NSColor(red: 0.50, green: 0.47, blue: 0.43, alpha: 1.0)
]
let fLeft = NSAttributedString(string: "⌘ 原生 Swift 5 · 零运行时依赖", attributes: footerLeftAttrs)
fLeft.draw(at: NSPoint(x: 36, y: footerY))

let footerRightStyle = NSMutableParagraphStyle()
footerRightStyle.alignment = .right
let footerRightAttrs: [NSAttributedString.Key: Any] = [
    .font: footerFont,
    .foregroundColor: NSColor(red: 0.50, green: 0.47, blue: 0.43, alpha: 1.0),
    .paragraphStyle: footerRightStyle
]
let fRight = NSAttributedString(string: "硬件级 AES-256 · 智能 MCP 扩展 · MIT 协议", attributes: footerRightAttrs)
fRight.draw(in: NSRect(x: widthPt - 370, y: footerY, width: 334, height: 16))

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    print("❌ 无法生成 PNG 图像数据")
    exit(1)
}

try data.write(to: outputURL)
print("✓ 成功生成复古纸质高品质 DMG 背景图: \(outputURL.path)")
