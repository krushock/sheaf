import CoreGraphics
import Foundation
import Vision

/// Finds the part of a picture the eye goes to, with the system's saliency model.
public enum PictureFraming {
    /// The part of a picture that matters, with a little room around it, in fractions of
    /// the picture's width and height from its bottom left corner. `nil` when nothing
    /// stands out, or when what does takes up nearly all of the picture anyway.
    public static func salientPart(of image: CGImage) -> PDFRectangle? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil, let objects = request.results?.first?.salientObjects, !objects.isEmpty else { return nil }
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        let box = objects.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -0.03, dy: -0.03).intersection(whole)
        guard !box.isNull, box.width > 0.05, box.height > 0.05, box.width * box.height < 0.85 else { return nil }
        return PDFRectangle(x: box.minX, y: box.minY, width: box.width, height: box.height)
    }
}
