import AppKit
import Foundation

private enum IconError: LocalizedError {
    case usage
    case unreadableSVG
    case missingPath
    case malformedPath(String)
    case bitmapCreationFailed(Int)
    case pngEncodingFailed(Int)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "用法: swift generate-app-icon.swift <FishLogo.svg> <AppIcon.iconset>"
        case .unreadableSVG:
            return "无法读取 FishLogo.svg"
        case .missingPath:
            return "FishLogo.svg 中没有找到 path d 属性"
        case .malformedPath(let token):
            return "无法解析 FishLogo path: \(token)"
        case .bitmapCreationFailed(let size):
            return "无法创建 \(size)x\(size) 位图"
        case .pngEncodingFailed(let size):
            return "无法编码 \(size)x\(size) PNG"
        }
    }
}

private struct SVGPathParser {
    private let tokens: [String]
    private var index = 0

    init(data: String) throws {
        let pattern = #"[MCLZ]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(data.startIndex..<data.endIndex, in: data)
        self.tokens = regex.matches(in: data, range: range).compactMap { match in
            guard let r = Range(match.range, in: data) else { return nil }
            return String(data[r])
        }
    }

    mutating func makePath() throws -> CGPath {
        let path = CGMutablePath()
        var command: String?

        while index < tokens.count {
            if Self.isCommand(tokens[index]) {
                command = tokens[index]
                index += 1
                if command == "Z" {
                    path.closeSubpath()
                    command = nil
                    continue
                }
            }

            guard let activeCommand = command else {
                throw IconError.malformedPath(tokens[index])
            }

            switch activeCommand {
            case "M":
                path.move(to: CGPoint(x: try number(), y: try number()))
                // SVG 规定同一 M 后续坐标对按 L 处理。
                command = "L"
            case "L":
                path.addLine(to: CGPoint(x: try number(), y: try number()))
            case "C":
                let c1 = CGPoint(x: try number(), y: try number())
                let c2 = CGPoint(x: try number(), y: try number())
                let end = CGPoint(x: try number(), y: try number())
                path.addCurve(to: end, control1: c1, control2: c2)
            default:
                throw IconError.malformedPath(activeCommand)
            }
        }

        return path
    }

    private mutating func number() throws -> CGFloat {
        guard index < tokens.count,
              !Self.isCommand(tokens[index]),
              let value = Double(tokens[index]) else {
            throw IconError.malformedPath(index < tokens.count ? tokens[index] : "<eof>")
        }
        index += 1
        return CGFloat(value)
    }

    private static func isCommand(_ token: String) -> Bool {
        token == "M" || token == "C" || token == "L" || token == "Z"
    }
}

private func extractPathData(from svg: String) throws -> String {
    let pattern = #"<path\s+[^>]*d=\"([^\"]+)\""#
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(svg.startIndex..<svg.endIndex, in: svg)
    guard let match = regex.firstMatch(in: svg, range: range),
          match.numberOfRanges > 1,
          let capture = Range(match.range(at: 1), in: svg) else {
        throw IconError.missingPath
    }
    return String(svg[capture])
}

private func renderIcon(path: CGPath, size: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw IconError.bitmapCreationFailed(size)
    }

    rep.size = NSSize(width: size, height: size)
    guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
        throw IconError.bitmapCreationFailed(size)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }

    let context = graphics.cgContext
    let unit = CGFloat(size) / 1024.0

    // Core Graphics 在 AppKit 位图里是左下原点；翻成 SVG 的左上原点坐标系。
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: unit, y: -unit)

    context.setFillColor(NSColor.white.cgColor)
    let tile = CGPath(
        roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
        cornerWidth: 204,
        cornerHeight: 204,
        transform: nil
    )
    context.addPath(tile)
    context.fillPath()

    context.saveGState()
    context.translateBy(x: 170, y: 260)
    context.scaleBy(x: 29.5, y: 29.5)
    context.setFillColor(NSColor(
        calibratedRed: 77.0 / 255.0,
        green: 107.0 / 255.0,
        blue: 254.0 / 255.0,
        alpha: 1
    ).cgColor)
    context.addPath(path)
    context.fillPath()
    context.restoreGState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw IconError.pngEncodingFailed(size)
    }
    return png
}

private let iconFiles: [(name: String, pixels: Int)] = [
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

do {
    guard CommandLine.arguments.count == 3 else { throw IconError.usage }
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    guard let svg = try? String(contentsOf: source, encoding: .utf8) else {
        throw IconError.unreadableSVG
    }

    let data = try extractPathData(from: svg)
    var parser = try SVGPathParser(data: data)
    let path = try parser.makePath()

    let fm = FileManager.default
    try? fm.removeItem(at: output)
    try fm.createDirectory(at: output, withIntermediateDirectories: true)

    for file in iconFiles {
        let png = try renderIcon(path: path, size: file.pixels)
        try png.write(to: output.appendingPathComponent(file.name), options: .atomic)
    }
} catch {
    fputs("错误：\(error.localizedDescription)\n", stderr)
    exit(2)
}
