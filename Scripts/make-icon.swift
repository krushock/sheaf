// Draws Sheaf's app icon and writes every size the asset catalog wants.
//
//     swift Scripts/make-icon.swift
//
// The icon is a sheaf: a few sheets of paper, fanned, held by a band.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sheaf/Resources/Assets.xcassets/AppIcon.appiconset")
let root = FileManager.default.fileExists(atPath: folder.path) ? folder : URL(fileURLWithPath: "Sheaf/Resources/Assets.xcassets/AppIcon.appiconset")

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func draw(size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)

    // The rounded square macOS icons sit in, with the usual margin around it.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.28))
    context.addPath(shape)
    context.setFillColor(color(40, 110, 220))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(74, 148, 250), color(28, 86, 196)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Three sheets, fanned about a point near the bottom.
    func sheet(angle: CGFloat, tint: CGColor, lines: Bool) {
        context.saveGState()
        context.translateBy(x: 512, y: 300)
        context.rotate(by: angle * .pi / 180)
        let page = CGRect(x: -210, y: -70, width: 420, height: 560)
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0, 20, 70, 0.35))
        context.addPath(CGPath(roundedRect: page, cornerWidth: 26, cornerHeight: 26, transform: nil))
        context.setFillColor(tint)
        context.fillPath()
        if lines {
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setFillColor(color(196, 204, 218))
            for (row, width) in [300.0, 300, 220, 300, 300, 160].enumerated() {
                let y = page.maxY - 86 - CGFloat(row) * 54
                context.addPath(CGPath(roundedRect: CGRect(x: page.minX + 60, y: y, width: width, height: 20), cornerWidth: 10, cornerHeight: 10, transform: nil))
            }
            context.fillPath()
        }
        context.restoreGState()
    }
    sheet(angle: 13, tint: color(214, 226, 246), lines: false)
    sheet(angle: -12, tint: color(232, 239, 250), lines: false)
    sheet(angle: 0, tint: color(255, 255, 255), lines: true)

    // The band that makes them a sheaf.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -5), blur: 12, color: color(0, 20, 70, 0.3))
    let band = CGRect(x: 262, y: 286, width: 500, height: 84)
    context.addPath(CGPath(roundedRect: band, cornerWidth: 20, cornerHeight: 20, transform: nil))
    context.setFillColor(color(255, 92, 72))
    context.fillPath()
    context.restoreGState()
    context.setFillColor(color(255, 255, 255, 0.22))
    context.fill(CGRect(x: band.minX, y: band.midY, width: band.width, height: band.height / 2 - 14))

    context.restoreGState()
    return context.makeImage()!
}

var entries: [[String: String]] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, draw(size: points * scale), nil)
        CGImageDestinationFinalize(destination)
        entries.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("Contents.json"))
try Data("{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n".utf8).write(to: root.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("Wrote \(entries.count) sizes to \(root.path)")
