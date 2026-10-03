import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Turns a photograph of a sheet of paper into a flat, squared-up picture of the sheet,
/// the way a scanner would have captured it.
public enum DocumentStraightener {
    /// Finds the sheet in a photograph, cuts it out and removes the perspective.
    ///
    /// - Parameter data: A JPEG, HEIC, PNG or other picture file.
    /// - Returns: The sheet as a JPEG, or `nil` when no sheet could be found, so the caller
    ///   can fall back to the photograph as it is.
    public static func straightened(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up

        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        guard (try? handler.perform([request])) != nil, let sheet = request.results?.first, sheet.confidence > 0.5 else { return nil }

        // Vision answers in fractions of the upright picture; Core Image wants pixels.
        let upright = CIImage(cgImage: image).oriented(orientation)
        let size = upright.extent.size
        func point(_ corner: CGPoint) -> CIVector {
            CIVector(x: upright.extent.minX + corner.x * size.width, y: upright.extent.minY + corner.y * size.height)
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(upright, forKey: kCIInputImageKey)
        filter.setValue(point(sheet.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(sheet.topRight), forKey: "inputTopRight")
        filter.setValue(point(sheet.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(point(sheet.bottomRight), forKey: "inputBottomRight")
        guard let flat = filter.outputImage, flat.extent.width >= 16, flat.extent.height >= 16,
              let result = CIContext().createCGImage(flat, from: flat.extent)
        else { return nil }
        return ImageReader.encodeJPEG(result, quality: 0.9)
    }
}
