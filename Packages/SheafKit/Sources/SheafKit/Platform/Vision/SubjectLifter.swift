import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Takes the background out of a picture, with the system's subject detection.
public enum SubjectLifter {
    /// The picture with everything but what it is a picture of made see-through, as a
    /// PNG file of the same size. `nil` when no subject stands out from a background.
    public static func subject(of image: CGImage) -> Data? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil, let result = request.results?.first, !result.allInstances.isEmpty,
              let buffer = try? result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        else { return nil }
        let lifted = CIImage(cvPixelBuffer: buffer)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CIContext().pngRepresentation(of: lifted, format: .RGBA8, colorSpace: space)
    }
}
