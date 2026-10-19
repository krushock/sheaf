import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SheafKit
import SwiftUI
import UniformTypeIdentifiers

/// How a picture's colors and light are changed, as in the Image tab of Pages. Each value
/// runs from -1 to 1 (sharpness from 0 to 1), 0 leaving the picture as it was.
struct PictureAdjustments: Equatable, Sendable {
    var exposure = 0.0
    var saturation = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var sharpness = 0.0
    var temperature = 0.0
    var tint = 0.0
    /// The system's automatic improvements, as Enhance in Photos and Pages.
    var isEnhanced = false

    var isNeutral: Bool { self == PictureAdjustments() }

    /// The picture with the adjustments made, or `nil` when Core Image could not do it.
    nonisolated func applied(to picture: CGImage) -> CGImage? {
        var image = CIImage(cgImage: picture)
        let extent = image.extent
        if isEnhanced {
            for filter in image.autoAdjustmentFilters(options: [.redEye: false]) {
                filter.setValue(image, forKey: kCIInputImageKey)
                if let output = filter.outputImage { image = output }
            }
        }
        if exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(exposure * 2)
            image = filter.outputImage ?? image
        }
        if saturation != 0 || contrast != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = Float(1 + saturation)
            filter.contrast = Float(1 + contrast * 0.5)
            filter.brightness = 0
            image = filter.outputImage ?? image
        }
        if shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.shadowAmount = Float(shadows)
            filter.highlightAmount = 1
            image = filter.outputImage ?? image
        }
        if highlights != 0 {
            // The upper part of the tone curve, raised or lowered.
            let filter = CIFilter.toneCurve()
            filter.inputImage = image
            filter.point0 = CGPoint(x: 0, y: 0)
            filter.point1 = CGPoint(x: 0.25, y: 0.25)
            filter.point2 = CGPoint(x: 0.5, y: 0.5)
            filter.point3 = CGPoint(x: 0.75, y: 0.75 + 0.15 * highlights)
            filter.point4 = CGPoint(x: 1, y: 1 + min(0, 0.1 * highlights))
            image = filter.outputImage ?? image
        }
        if temperature != 0 || tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: 6500, y: 0)
            // Warmer means the picture's white is taken for a bluer light.
            filter.targetNeutral = CIVector(x: 6500 - 2500 * temperature, y: 60 * tint)
            image = filter.outputImage ?? image
        }
        if sharpness > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(sharpness * 2)
            image = filter.outputImage ?? image
        }
        let space = picture.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [.workingColorSpace: space]).createCGImage(image.cropped(to: extent), from: extent, format: .RGBA8, colorSpace: space)
    }
}

/// The picture as it was before the adjustments of this selection began, so that each
/// change starts from it rather than from the last, and Reset can go back to it.
struct AdjustmentSession {
    var pageIndex: Int
    var imageID: Int
    var original: CGImage
    var settings: PictureAdjustments
    /// The document's revision after the last adjustment. Any other change since, an undo
    /// for one, ends the session.
    var revision: Int
}

extension ViewerModel {
    /// The adjustments made to the selected picture since it was selected.
    var selectedPictureAdjustments: PictureAdjustments {
        guard case .image(let pageIndex, let id) = contentSelection, let session = adjustmentSession,
              session.pageIndex == pageIndex, session.imageID == id, session.revision == sheafDocument?.revision
        else { return PictureAdjustments() }
        return session.settings
    }

    /// Changes the selected picture's colors and light, starting from how it was when the
    /// adjustments began. One Undo takes back each change.
    func adjustSelectedPicture(_ settings: PictureAdjustments) {
        guard case .image(let pageIndex, let id) = contentSelection, let image = selectedImage, image.isEditable,
              pictureWork == nil, let sheafDocument, settings != selectedPictureAdjustments
        else { return }
        let session = adjustmentSession.flatMap { $0.pageIndex == pageIndex && $0.imageID == id && $0.revision == sheafDocument.revision ? $0 : nil }
        guard let original = session?.original ?? pictureImage(of: image, pageIndex: pageIndex) else { return }
        let revision = sheafDocument.revision
        pictureWork = .adjusting
        Task {
            let data = await Task.detached { () -> Data? in
                guard let adjusted = settings.applied(to: original) else { return nil }
                return Self.pictureFile(adjusted)
            }.value
            pictureWork = nil
            guard let data, sheafDocument.revision == revision, contentSelection == .image(pageIndex: pageIndex, id: id) else { return }
            let changed = changeContent(String(localized: "Adjust Picture"), pageIndex: pageIndex, following: image.frame) {
                try $0.replaceImage(id, onPageAt: pageIndex, with: data, keepingShape: true)
            }
            if changed {
                adjustmentSession = AdjustmentSession(pageIndex: pageIndex, imageID: id, original: original, settings: settings, revision: sheafDocument.revision)
            }
        }
    }

    /// A picture as a file for the document: JPEG when it is opaque, PNG when it is not.
    nonisolated static func pictureFile(_ image: CGImage) -> Data? {
        let opaque = !hasTransparency(image)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (opaque ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, opaque ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary : nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Turns the selected picture a quarter turn, or by any angle, about its middle.
    func rotateSelectedPicture(by degrees: Double) {
        guard case .image(let pageIndex, let id) = contentSelection, let image = selectedImage, image.isEditable, maskEdit == nil else { return }
        setSelectedPictureAngle(image.placement.rotation + degrees)
    }

    /// Sets the selected picture's angle, counterclockwise, in degrees.
    func setSelectedPictureAngle(_ degrees: Double) {
        guard case .image(let pageIndex, let id) = contentSelection, let image = selectedImage, image.isEditable, maskEdit == nil else { return }
        var placement = image.placement
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        if abs(angle - 360) < 0.05 { angle = 0 }
        guard abs(angle - placement.rotation) > 0.05 else { return }
        placement.rotation = angle
        changeContent(String(localized: "Rotate Picture"), pageIndex: pageIndex, following: placement.frame) {
            try $0.setImagePlacement(placement, ofImage: id, onPageAt: pageIndex)
        }
    }
}

/// A knob for turning a picture, as in the Arrange tab of Pages: drag it round, and the
/// picture turns when it is let go.
struct RotationKnob: View {
    let angle: Double
    let onChange: (Double) -> Void
    @State private var dragged: Double?

    var body: some View {
        let shown = dragged ?? angle
        ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor)))
            // A mark from the middle toward the angle, counterclockwise from three o'clock.
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 2, height: 9)
                .offset(y: -5)
                .rotationEffect(.degrees(90 - shown))
        }
        .frame(width: 24, height: 24)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = value.location.x - 12, dy = 12 - value.location.y
                    guard dx * dx + dy * dy > 4 else { return }
                    var degrees = atan2(dy, dx) * 180 / .pi
                    if degrees < 0 { degrees += 360 }
                    // Shift snaps to 15°, as dragging a handle does to 45°.
                    if NSEvent.modifierFlags.contains(.shift) { degrees = (degrees / 15).rounded() * 15 }
                    dragged = degrees.rounded()
                }
                .onEnded { _ in
                    if let dragged { onChange(dragged) }
                    dragged = nil
                }
        )
        .help("Drag to turn the picture. Hold Shift for steps of 15°.")
        .accessibilityElement()
        .accessibilityLabel("Rotate")
        .accessibilityValue(Text("\(Int(shown.rounded()))°"))
        .accessibilityAdjustableAction { direction in
            onChange(angle + (direction == .increment ? 1 : -1))
        }
    }
}

/// The Adjustments section of the Format panel for a picture.
struct PictureAdjustmentControls: View {
    let viewer: ViewerModel
    @State private var settings = PictureAdjustments()

    var body: some View {
        Section("Adjustments") {
            slider("Exposure", \.exposure)
            slider("Saturation", \.saturation)
            HStack {
                Toggle("Enhance", isOn: Binding(get: { settings.isEnhanced }, set: { settings.isEnhanced = $0; viewer.adjustSelectedPicture(settings) }))
                    .toggleStyle(.button)
                    .help("Let the system improve the picture's light and color")
                Spacer()
                if viewer.pictureWork == .adjusting { ProgressView().controlSize(.small) }
            }
            DisclosureGroup("More Adjustments") {
                slider("Contrast", \.contrast)
                slider("Highlights", \.highlights)
                slider("Shadows", \.shadows)
                slider("Sharpness", \.sharpness, range: 0...1)
                slider("Temperature", \.temperature)
                slider("Tint", \.tint)
            }
            ActionRow("Reset Adjustments", systemImage: "arrow.counterclockwise") {
                settings = PictureAdjustments()
                viewer.adjustSelectedPicture(settings)
            }
            .disabled(viewer.selectedPictureAdjustments.isNeutral)
        }
        .disabled(viewer.pictureWork != nil && viewer.pictureWork != .adjusting)
        .onChange(of: viewer.selectedPictureAdjustments, initial: true) { settings = viewer.selectedPictureAdjustments }
    }

    /// A slider on a row of its own, the picture changing when it is let go.
    private func slider(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<PictureAdjustments, Double>, range: ClosedRange<Double> = -1...1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(settings[keyPath: keyPath], format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = ($0 * 100).rounded() / 100 }), in: range) { isEditing in
                if !isEditing { viewer.adjustSelectedPicture(settings) }
            }
            .accessibilityLabel(title)
        }
    }
}
