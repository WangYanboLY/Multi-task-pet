import AppKit
import CoreGraphics
import Foundation

// Run with: swift native/GenerateIcon.swift /path/to/AgentPet.iconset [main|gpt|claude]
// All geometry is defined on a 1024-point canvas and rasterized at each icon size.

private let canvasSize: CGFloat = 1024
private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}

private struct IconPalette {
    let background: CGColor
    let ear: CGColor
    let shadow: CGColor
    let head: CGColor
    let highlight: CGColor
    let eye: CGColor
    let cheek: CGColor

    static func named(_ name: String) -> IconPalette? {
        switch name {
        case "main":
            return IconPalette(
                background: color(0.075, 0.095, 0.16),
                ear: color(0.20, 0.53, 0.55),
                shadow: color(0.02, 0.10, 0.15, 0.52),
                head: color(0.19, 0.68, 0.72),
                highlight: color(0.59, 1.0, 0.87),
                eye: color(0.07, 0.22, 0.31),
                cheek: color(1, 0.59, 0.68, 0.6)
            )
        case "gpt":
            return IconPalette(
                background: color(0.075, 0.095, 0.16),
                ear: color(0.32, 0.41, 0.52),
                shadow: color(0.02, 0.06, 0.13, 0.52),
                head: color(0.44, 0.56, 0.70),
                highlight: color(0.75, 0.83, 0.92),
                eye: color(0.10, 0.19, 0.29),
                cheek: color(0.94, 0.74, 0.78, 0.52)
            )
        case "claude":
            return IconPalette(
                background: color(0.13, 0.085, 0.09),
                ear: color(0.64, 0.32, 0.24),
                shadow: color(0.18, 0.07, 0.06, 0.52),
                head: color(0.851, 0.467, 0.341),
                highlight: color(1.0, 0.72, 0.54),
                eye: color(0.25, 0.13, 0.12),
                cheek: color(1, 0.81, 0.73, 0.62)
            )
        default:
            return nil
        }
    }
}

private func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private func drawEar(in context: CGContext, center: CGPoint, angle: CGFloat, palette: IconPalette) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: angle * .pi / 180)
    context.addPath(roundedRect(CGRect(x: -73, y: -158, width: 146, height: 316), radius: 73))
    context.setFillColor(palette.ear)
    context.fillPath()
    context.restoreGState()
}

private func renderIcon(pixelSize: Int, palette: IconPalette) throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "GenerateIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create bitmap context"])
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(pixelSize) / canvasSize, y: CGFloat(pixelSize) / canvasSize)

    // A solid background keeps each face recognizable in light and dark notifications.
    context.addPath(roundedRect(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize), radius: 218))
    context.setFillColor(palette.background)
    context.fillPath()

    // The ears sit behind the head, as in PetView.
    drawEar(in: context, center: CGPoint(x: 341, y: 724), angle: 25, palette: palette)
    drawEar(in: context, center: CGPoint(x: 683, y: 724), angle: -25, palette: palette)

    let head = roundedRect(CGRect(x: 180, y: 176, width: 664, height: 640), radius: 300)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -17), blur: 28,
                      color: palette.shadow)
    context.addPath(head)
    context.setFillColor(palette.head)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(head)
    context.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [palette.highlight, palette.head] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 245, y: 795),
                               end: CGPoint(x: 805, y: 200),
                               options: [])

    if pixelSize >= 64 {
        context.saveGState()
        context.translateBy(x: 385, y: 705)
        context.rotate(by: 28 * .pi / 180)
        context.addEllipse(in: CGRect(x: -151, y: -48, width: 302, height: 96))
        context.setFillColor(color(1, 1, 1, 0.23))
        context.fillPath()
        context.restoreGState()
    }
    context.restoreGState()

    let small = pixelSize <= 32
    let eyeWidth: CGFloat = small ? 76 : 62
    let eyeHeight: CGFloat = small ? 120 : 108
    let eyeColor = palette.eye
    for centerX: CGFloat in [388, 636] {
        context.addPath(roundedRect(
            CGRect(x: centerX - eyeWidth / 2, y: 475, width: eyeWidth, height: eyeHeight),
            radius: eyeWidth / 2
        ))
        context.setFillColor(eyeColor)
        context.fillPath()
    }

    if pixelSize >= 32 {
        context.setFillColor(palette.cheek)
        context.fillEllipse(in: CGRect(x: 267, y: 385, width: 91, height: 55))
        context.fillEllipse(in: CGRect(x: 666, y: 385, width: 91, height: 55))
    }

    context.beginPath()
    context.move(to: CGPoint(x: 452, y: 381))
    context.addCurve(to: CGPoint(x: 572, y: 381),
                     control1: CGPoint(x: 475, y: 315),
                     control2: CGPoint(x: 549, y: 315))
    context.setStrokeColor(eyeColor)
    context.setLineWidth(small ? 43 : 34)
    context.setLineCap(.round)
    context.strokePath()

    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode PNG"])
    }
    return png
}

private let iconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

guard (2...3).contains(CommandLine.arguments.count),
      let palette = IconPalette.named(CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "main") else {
    fputs("Usage: GenerateIcon /path/to/AgentPet.iconset [main|gpt|claude]\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for (name, pixels) in iconSizes {
        try renderIcon(pixelSize: pixels, palette: palette)
            .write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
    }
    print("Generated \(outputDirectory.path)")
} catch {
    fputs("GenerateIcon: \(error)\n", stderr)
    exit(1)
}
