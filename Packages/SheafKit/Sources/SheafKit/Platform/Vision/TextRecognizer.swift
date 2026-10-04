import CoreGraphics
import Foundation
import ImageIO
import Vision

/// A line of text found in a picture.
public struct RecognizedText: Sendable, Equatable {
    public var text: String
    /// Where the line is, in fractions of the picture, measured from its bottom left corner.
    public var frame: PDFRectangle

    /// The line's words, each with where it is, when the recognizer could tell them apart.
    public var words: [RecognizedText]

    public init(text: String, frame: PDFRectangle, words: [RecognizedText] = []) {
        self.text = text
        self.frame = frame
        self.words = words
    }
}

/// Reads the text in pictures of pages, with the system's text recognition.
public enum TextRecognizer {
    /// - Parameter languages: Language codes to expect, most likely first, such as
    ///   `["ru", "en"]`. Empty lets the system work out the language.
    public static func recognize(in image: CGImage, languages: [String] = []) -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first, !best.string.isEmpty else { return nil }
            let box = observation.boundingBox
            // Word by word, so each one lies over its own place in the picture.
            var words: [RecognizedText] = []
            let string = best.string
            var start = string.startIndex
            while start < string.endIndex {
                guard !string[start].isWhitespace else {
                    start = string.index(after: start)
                    continue
                }
                let end = string[start...].firstIndex(where: \.isWhitespace) ?? string.endIndex
                if let found = try? best.boundingBox(for: start..<end)?.boundingBox, found.width > 0, found.height > 0 {
                    words.append(RecognizedText(text: String(string[start..<end]), frame: PDFRectangle(x: found.minX, y: found.minY, width: found.width, height: found.height)))
                } else {
                    // Without a place for every word the line is laid out as a whole.
                    words = []
                    break
                }
                start = end
            }
            return RecognizedText(text: string, frame: PDFRectangle(x: box.minX, y: box.minY, width: box.width, height: box.height), words: words)
        }
    }

    /// Reads the text in a picture file.
    public static func recognize(inImageData data: Data, languages: [String] = []) -> [RecognizedText] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return recognize(in: image, languages: languages)
    }
}
