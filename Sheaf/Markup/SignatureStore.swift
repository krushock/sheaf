import AppKit
import ImageIO
import SheafKit
import SwiftUI
import UniformTypeIdentifiers

/// A signature kept for reuse.
struct SavedSignature: Codable, Identifiable, Equatable {
    enum Content: Codable, Equatable {
        /// Pen strokes inside the unit square.
        case strokes([[PDFPoint]], lineWidth: Double)
        /// Filled outlines inside the unit square, from a typed name.
        case shapes([PathElement])
        /// A PNG with a transparent background.
        case image(Data)
    }

    var id = UUID()
    var content: Content
    /// Width divided by height.
    var aspectRatio: Double

    /// What a stamp annotation needs to show this signature.
    func stampContent() -> Annotation.StampContent? {
        switch content {
        case .strokes(let strokes, let lineWidth): .strokes(strokes, lineWidth: lineWidth)
        case .shapes(let elements): .shapes(elements)
        case .image(let png): (try? StampImage(encodedImageData: png)).map(Annotation.StampContent.image)
        }
    }
}

/// The signatures saved on this Mac, kept in the app's Application Support folder.
@Observable
final class SignatureStore {
    static let shared = SignatureStore()

    private(set) var signatures: [SavedSignature] = []

    private let fileURL: URL? = {
        guard let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let own = folder.appendingPathComponent("Sheaf", isDirectory: true)
        try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        return own.appendingPathComponent("Signatures.json")
    }()

    private init() {
        if let fileURL, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([SavedSignature].self, from: data) {
            signatures = saved
        }
    }

    func add(_ signature: SavedSignature) {
        signatures.append(signature)
        save()
    }

    func remove(_ signature: SavedSignature) {
        signatures.removeAll { $0.id == signature.id }
        save()
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(signatures) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Builds signatures from what the person drew, typed or photographed.
enum SignatureMaker {
    /// Strokes as drawn in a view, scaled to fill the unit square.
    static func signature(fromStrokes strokes: [[CGPoint]]) -> SavedSignature? {
        let points = strokes.flatMap { $0 }
        guard points.count > 1, let bounds = PDFRectangle(enclosing: points.map { PDFPoint($0) }) else { return nil }
        let width = max(bounds.width, 1), height = max(bounds.height, 1)
        let normalized = strokes.filter { !$0.isEmpty }.map { stroke in
            stroke.map { PDFPoint(x: ($0.x - bounds.x) / width, y: ($0.y - bounds.y) / height) }
        }
        // The pen was two and a half points wide where it was drawn. The points are kept
        // without it, and the pen's width is added around them wherever they are shown.
        return SavedSignature(content: .strokes(normalized, lineWidth: 2.5 / (min(width, height) + 2.5)), aspectRatio: (width + 2.5) / (height + 2.5))
    }

    /// A name set in a script typeface, as outlines.
    static func signature(fromText text: String, fontName: String) -> SavedSignature? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let elements = TextOutliner.outline(line: trimmed, fontName: fontName, fitting: PDFRectangle(x: 0, y: 0, width: 2000, height: 400))
        let points = elements.flatMap { element -> [PDFPoint] in
            switch element {
            case .move(let point), .line(let point): [point]
            case .curve(let control1, let control2, let end): [control1, control2, end]
            case .close: []
            }
        }
        guard let bounds = PDFRectangle(enclosing: points), bounds.width > 0, bounds.height > 0 else { return nil }
        func place(_ point: PDFPoint) -> PDFPoint {
            PDFPoint(x: (point.x - bounds.x) / bounds.width, y: (point.y - bounds.y) / bounds.height)
        }
        let normalized = elements.map { element -> PathElement in
            switch element {
            case .move(let point): .move(place(point))
            case .line(let point): .line(place(point))
            case .curve(let control1, let control2, let end): .curve(control1: place(control1), control2: place(control2), end: place(end))
            case .close: .close
            }
        }
        return SavedSignature(content: .shapes(normalized), aspectRatio: bounds.width / bounds.height)
    }

    /// A photo or scan of a signature on paper: the paper is made transparent and the
    /// picture is cropped to the ink.
    static func signature(fromImageData data: Data) -> SavedSignature? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1400,
              ] as CFDictionary)
        else { return nil }
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Transparent images are judged against white paper.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var (minX, minY, maxX, maxY) = (width, height, -1, -1)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let luminance = 0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.114 * Double(pixels[offset + 2])
                // Dark is ink, light is paper, with a soft edge between.
                let alpha = min(max((205 - luminance) / 90, 0), 1)
                let value = UInt8(alpha * 255)
                for channel in 0..<3 { pixels[offset + channel] = UInt8(Double(pixels[offset + channel]) * alpha) }
                pixels[offset + 3] = value
                if value > 24 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX > minX, maxY > minY, let whole = context.makeImage(),
              let cropped = whole.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return SavedSignature(content: .image(output as Data), aspectRatio: Double(cropped.width) / Double(cropped.height))
    }
}

extension ViewerModel {
    func place(_ signature: SavedSignature) {
        guard let content = signature.stampContent() else { return }
        let isImage = if case .image = signature.content { true } else { false }
        pdfView.closeFieldPopover()
        if let target = signatureTarget {
            // Into the signature field that was clicked, as large as fits it.
            signatureTarget = nil
            let space = target.rect
            let width = min(space.width, space.height * signature.aspectRatio) * 0.92, height = width / max(signature.aspectRatio, 0.05)
            var stamp = Annotation(kind: .stamp, rect: PDFRectangle(x: space.x + (space.width - width) / 2, y: space.y + (space.height - height) / 2, width: width, height: height))
            stamp.stamp = content
            stamp.color = isImage ? nil : .black
            stamp.author = NSFullUserName()
            sheafDocument?.apply(String(localized: "Add Signature")) { editor, effect in
                effect.pages = [target.pageIndex]
                try editor.addAnnotation(stamp, toPageAt: target.pageIndex)
            }
            return
        }
        placeStamp(content, width: 190, aspectRatio: signature.aspectRatio, color: isImage ? nil : .black, name: String(localized: "Add Signature"))
    }
}
