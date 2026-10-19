import CoreImage
import CoreMedia
import Foundation
import VideoToolbox

/// Makes a small picture larger and sharper with the system's super resolution model,
/// the one Pages uses under the same name. The model works on this Mac. macOS
/// downloads it from Apple the first time it is wanted.
nonisolated enum SuperResolution {
    enum Failure: LocalizedError {
        case unsupported
        case tooLarge
        case tooSmall
        case transparent
        case failed

        var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "This Mac does not support Super Resolution.")
            case .tooLarge: String(localized: "This picture already has plenty of pixels. Super Resolution is for pictures up to 1920 pixels on a side.")
            case .tooSmall: String(localized: "This picture is too small for Super Resolution.")
            case .transparent: String(localized: "Super Resolution works on pictures without see-through parts.")
            case .failed: String(localized: "Super Resolution could not work on this picture.")
            }
        }
    }

    /// Whether the model is on this Mac, has to be downloaded, or is on its way.
    enum ModelState: Equatable {
        case ready, downloadRequired, downloading, unsupported
    }

    /// The largest side of a picture the model takes, and the smallest worth giving it.
    static let maximumSide = 1920
    static let minimumSide = 32

    static var isSupported: Bool { VTSuperResolutionScalerConfiguration.isSupported }

    /// How many times larger a picture comes out.
    static var scaleFactor: Int { VTSuperResolutionScalerConfiguration.supportedScaleFactors.max() ?? 0 }

    private static func configuration(width: Int, height: Int) -> VTSuperResolutionScalerConfiguration? {
        guard isSupported, scaleFactor > 1 else { return nil }
        return VTSuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: scaleFactor, inputType: .image, usePrecomputedFlow: false, qualityPrioritization: .normal, revision: VTSuperResolutionScalerConfiguration.defaultRevision)
    }

    static var modelState: ModelState {
        guard let configuration = configuration(width: 512, height: 512) else { return .unsupported }
        switch configuration.configurationModelStatus {
        case .ready: return .ready
        case .downloading: return .downloading
        case .downloadRequired: return .downloadRequired
        @unknown default: return .downloadRequired
        }
    }

    /// Has macOS download the model, reporting how far it has come, from 0 to 1.
    @concurrent static func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let configuration = configuration(width: 512, height: 512) else { throw Failure.unsupported }
        guard configuration.configurationModelStatus != .ready else { return }
        let watcher = Task {
            while !Task.isCancelled {
                progress(Double(configuration.configurationModelPercentageAvailable))
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { watcher.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            configuration.downloadConfigurationModel { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// The picture with its pixels multiplied by `scaleFactor` each way.
    @concurrent static func enlarged(_ image: CGImage) async throws -> CGImage {
        guard image.width <= maximumSide, image.height <= maximumSide else { throw Failure.tooLarge }
        guard image.width >= minimumSide, image.height >= minimumSide else { throw Failure.tooSmall }
        guard let configuration = configuration(width: image.width, height: image.height) else { throw Failure.unsupported }
        let factor = configuration.scaleFactor

        var source: CVPixelBuffer?
        var destination: CVPixelBuffer?
        let sourceAttributes = configuration.sourcePixelBufferAttributes as CFDictionary
        let destinationAttributes = configuration.destinationPixelBufferAttributes as CFDictionary
        let format = (configuration.sourcePixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? [NSNumber])?.first?.uint32Value
            ?? (configuration.sourcePixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
            ?? kCVPixelFormatType_32BGRA
        let outputFormat = (configuration.destinationPixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? [NSNumber])?.first?.uint32Value
            ?? (configuration.destinationPixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
            ?? format
        guard CVPixelBufferCreate(nil, image.width, image.height, format, sourceAttributes, &source) == kCVReturnSuccess, let source,
              CVPixelBufferCreate(nil, image.width * factor, image.height * factor, outputFormat, destinationAttributes, &destination) == kCVReturnSuccess, let destination
        else { throw Failure.failed }

        // Core Image converts to and from whatever kind of pixels the model works in.
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: space])
        context.render(CIImage(cgImage: image), to: source, bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), colorSpace: space)

        guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: .zero),
              let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: .zero),
              let parameters = VTSuperResolutionScalerParameters(sourceFrame: sourceFrame, previousFrame: nil, previousOutputFrame: nil, opticalFlow: nil, submissionMode: .random, destinationFrame: destinationFrame)
        else { throw Failure.failed }

        let processor = VTFrameProcessor()
        try processor.startSession(configuration: configuration)
        defer { processor.endSession() }
        try await processor.process(parameters: parameters)

        let result = CIImage(cvPixelBuffer: destination, options: [.colorSpace: space])
        guard let enlarged = context.createCGImage(result, from: result.extent, format: .RGBA8, colorSpace: space) else { throw Failure.failed }
        return enlarged
    }
}
