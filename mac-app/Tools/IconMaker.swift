// 生成本地 App 图标：蓝紫渐变文件夹与自动整理标记，不依赖第三方素材。

import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("需要传入 iconset 输出目录") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in variants {
    let size = NSSize(width: pixels, height: pixels)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("图标画布创建失败")
    }
    // 使用固定像素位图，避免 Retina backing scale 把 1024px 图标意外输出为 2048px。
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    NSGraphicsContext.current?.imageInterpolation = .high
    let inset = CGFloat(pixels) * 0.06
    let rect = NSRect(x: inset, y: inset, width: CGFloat(pixels) - inset * 2, height: CGFloat(pixels) - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.18, green: 0.48, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.45, green: 0.22, blue: 0.88, alpha: 1),
    ])!.draw(in: path, angle: -55)

    if let symbol = NSImage(systemSymbolName: "folder.fill.badge.gearshape", accessibilityDescription: nil) {
        let configuration = NSImage.SymbolConfiguration(pointSize: CGFloat(pixels) * 0.47, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .white]))
        let configured = symbol.withSymbolConfiguration(configuration) ?? symbol
        let symbolSize = configured.size
        let scale = min(CGFloat(pixels) * 0.68 / symbolSize.width, CGFloat(pixels) * 0.68 / symbolSize.height)
        let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
        configured.draw(in: NSRect(
            x: (CGFloat(pixels) - drawSize.width) / 2,
            y: (CGFloat(pixels) - drawSize.height) / 2 - CGFloat(pixels) * 0.015,
            width: drawSize.width,
            height: drawSize.height
        ))
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("图标生成失败")
    }
    try png.write(to: output.appendingPathComponent(name))
}
