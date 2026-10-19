import AppKit
import FoundationModels
import ImageIO
import ImagePlayground
import PDFKit
import SheafKit
import SwiftUI
import UniformTypeIdentifiers

/// What is being done to the selected picture that takes a moment.
enum PictureWork: Equatable {
    case cropping, enlarging, describing, adjusting
    /// The model for Super Resolution is on its way from Apple, this far along, from 0 to 1.
    case downloading(Double)
}

/// What Apple Intelligence says a picture shows.
struct PictureDescription: Equatable {
    var pageIndex: Int
    var imageID: Int
    var text: String
}

/// What the system's models do with the pictures on a page: reframe, sharpen, describe, make new ones.
extension ViewerModel {
    private var selectedEditablePicture: (pageIndex: Int, id: Int, image: PageImage, picture: CGImage)? {
        guard case .image(let pageIndex, let id) = contentSelection, let image = selectedImage, image.isEditable, pictureWork == nil,
              let picture = pictureImage(of: image, pageIndex: pageIndex)
        else { return nil }
        return (pageIndex, id, image, picture)
    }

    // MARK: Auto Crop

    /// Masks the selected picture down to the part of it that matters. The whole picture
    /// stays in the document, so Edit Mask and Reset Mask work on the result.
    func autoCropSelectedPicture() {
        guard let (pageIndex, id, image, picture) = selectedEditablePicture, let sheafDocument else { return }
        let revision = sheafDocument.revision
        pictureWork = .cropping
        Task {
            let found = await Task.detached { PictureFraming.salientPart(of: picture) }.value
            pictureWork = nil
            guard sheafDocument.revision == revision, contentSelection == .image(pageIndex: pageIndex, id: id) else { return }
            guard var part = found else {
                editMessage = String(localized: "Nothing in this picture stands out enough to crop to.")
                return
            }
            // The part was found in the picture as the file has it; a mirrored one shows the other way round.
            if image.placement.isMirrored { part.x = 1 - part.x - part.width }
            changeContent(String(localized: "Auto Crop"), pageIndex: pageIndex, following: image.frame) {
                try $0.setImageMask(part, ofImage: id, onPageAt: pageIndex)
            }
        }
    }

    // MARK: Super Resolution

    /// Whether Super Resolution is offered at all on this Mac.
    var offersSuperResolution: Bool { SuperResolution.isSupported }

    /// Makes the selected picture four times larger in pixels, and sharper, in the same place.
    func enlargeSelectedPicture() {
        guard let (pageIndex, id, image, picture) = selectedEditablePicture, let sheafDocument else { return }
        guard picture.width <= SuperResolution.maximumSide, picture.height <= SuperResolution.maximumSide,
              image.pixelWidth <= SuperResolution.maximumSide, image.pixelHeight <= SuperResolution.maximumSide
        else {
            editMessage = SuperResolution.Failure.tooLarge.localizedDescription
            return
        }
        guard !Self.hasTransparency(picture) else {
            editMessage = SuperResolution.Failure.transparent.localizedDescription
            return
        }
        switch SuperResolution.modelState {
        case .unsupported:
            editMessage = SuperResolution.Failure.unsupported.localizedDescription
            return
        case .downloadRequired:
            // The person says yes to a download before one starts.
            isSuperResolutionDownloadPresented = true
            return
        case .downloading:
            editMessage = String(localized: "Super Resolution is still being downloaded. Try again in a while.")
            return
        case .ready:
            break
        }
        let revision = sheafDocument.revision
        pictureWork = .enlarging
        Task {
            defer { pictureWork = nil }
            do {
                let enlarged = try await SuperResolution.enlarged(picture)
                guard sheafDocument.revision == revision, contentSelection == .image(pageIndex: pageIndex, id: id) else { return }
                guard let data = await Task.detached(operation: { Self.encoded(enlarged) }).value else { throw SuperResolution.Failure.failed }
                changeContent(String(localized: "Super Resolution"), pageIndex: pageIndex, following: image.frame) {
                    try $0.replaceImage(id, onPageAt: pageIndex, with: data, keepingShape: true)
                }
            } catch {
                editMessage = error.localizedDescription
            }
        }
    }

    /// Has macOS fetch the model, then goes on to enlarge the picture.
    func downloadSuperResolutionAndEnlarge() {
        guard pictureWork == nil else { return }
        pictureWork = .downloading(0)
        Task {
            do {
                try await SuperResolution.downloadModel { fraction in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.pictureWork { self?.pictureWork = .downloading(fraction) }
                    }
                }
                pictureWork = nil
                enlargeSelectedPicture()
            } catch {
                pictureWork = nil
                editMessage = String(localized: "Super Resolution could not be downloaded. \(error.localizedDescription)")
            }
        }
    }

    /// Whether any of a picture is see-through.
    nonisolated static func hasTransparency(_ image: CGImage) -> Bool {
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else { return false }
        // Looked at small: a see-through part of any size shows there too.
        let width = min(image.width, 256), height = min(image.height, 256)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for index in 0..<(width * height) where pixels[index * 4 + 3] < 250 { return true }
        return false
    }

    /// An enlarged picture as a file for the document: a JPEG, no more than 4096 pixels on
    /// a side, which is past what a page shows at any zoom and keeps the file a sensible size.
    private nonisolated static func encoded(_ image: CGImage) -> Data? {
        var image = image
        let longest = max(image.width, image.height)
        if longest > 4096 {
            let scale = 4096 / Double(longest)
            let width = Int((Double(image.width) * scale).rounded()), height = Int((Double(image.height) * scale).rounded())
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let smaller = context.makeImage() else { return nil }
            image = smaller
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Description

    /// Whether the model on this Mac can say what a picture shows.
    var canDescribePictures: Bool { DocumentReader.canDescribePictures }

    /// The description made of the selected picture, if one was.
    var selectedPictureDescription: String? {
        guard case .image(let pageIndex, let id) = contentSelection, let description = pictureDescription,
              description.pageIndex == pageIndex, description.imageID == id
        else { return nil }
        return description.text
    }

    /// Has Apple Intelligence say what the selected picture shows. The description is
    /// shown in the Format panel, to copy or to put on the page as a note.
    func describeSelectedPicture() {
        guard #available(macOS 27.0, *), case .image(let pageIndex, let id) = contentSelection, let image = selectedImage, pictureWork == nil,
              let picture = pictureImage(of: image, pageIndex: pageIndex)
        else { return }
        pictureWork = .describing
        Task {
            defer { pictureWork = nil }
            do {
                let text = try await DocumentReader.describe(picture, language: DocumentReader.replyLanguage)
                pictureDescription = PictureDescription(pageIndex: pageIndex, imageID: id, text: text)
            } catch {
                editMessage = error.localizedDescription
            }
        }
    }

    // MARK: Image Playground

    /// Whether Image Playground can be opened on this Mac.
    var offersImagePlayground: Bool { ImagePlaygroundViewController.isAvailable }

    /// Opens Image Playground to make a picture for the page. Selected text is what the
    /// picture starts from, and a selected picture is what it is made from.
    func openImagePlayground() {
        guard canEditPages, offersImagePlayground else { return }
        if let text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            playgroundConcepts = [.extracted(from: text, title: nil)]
        } else if let block = selectedBlock, !block.text.isEmpty {
            playgroundConcepts = [.extracted(from: block.text, title: nil)]
        } else {
            playgroundConcepts = []
        }
        if case .image(let pageIndex, _) = contentSelection, let image = selectedImage, let picture = pictureImage(of: image, pageIndex: pageIndex) {
            playgroundSource = Image(decorative: picture, scale: 1)
        } else {
            playgroundSource = nil
        }
        isImagePlaygroundPresented = true
    }

    /// Puts the picture Image Playground made on the page being read, marked in its
    /// metadata as made by a generative model (IPTC's "trainedAlgorithmicMedia"), since
    /// whatever mark Apple put in the file is lost when it becomes part of the PDF.
    func addPlaygroundPicture(at url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        addPicture(data, generatedBy: "Image Playground")
    }
}
