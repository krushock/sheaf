import AVFoundation
import NaturalLanguage
import PDFKit

/// View > Read Out Loud: the document read aloud by the Mac's own voices, from the page
/// being read on, page after page, as Acrobat's Read Out Loud does. Nothing leaves the Mac.
@Observable final class PageReader: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// The page each queued utterance reads.
    @ObservationIgnored private var pages: [ObjectIdentifier: Int] = [:]
    /// Called with each page as reading reaches it.
    @ObservationIgnored var onPage: ((Int) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Reads from a page to the end. Pages without text, such as scans that were never
    /// recognized, are passed over.
    func start(_ document: PDFDocument, from index: Int) {
        stop()
        guard index < document.pageCount else { return }
        for pageIndex in index..<document.pageCount {
            guard let text = document.page(at: pageIndex)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = Self.voice(for: text)
            pages[ObjectIdentifier(utterance)] = pageIndex
            synthesizer.speak(utterance)
        }
        isSpeaking = !pages.isEmpty
    }

    func stop() {
        pages = [:]
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// The person's chosen voice for the language the text is in.
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return AVSpeechSynthesisVoice(language: language.rawValue)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let page = self.pages[id] { self.onPage?(page) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.pages.removeValue(forKey: id) != nil else { return }
            if self.pages.isEmpty { self.isSpeaking = false }
        }
    }
}

extension ViewerModel {
    var isReadingAloud: Bool { pageReader.isSpeaking }

    /// Starts reading from the page being read, or stops.
    func toggleReadingAloud() {
        if pageReader.isSpeaking {
            pageReader.stop()
            return
        }
        guard let document else { return }
        pageReader.onPage = { [weak self] index in
            guard let self, index != self.currentPageIndex else { return }
            self.goToPage(index: index)
        }
        pageReader.start(document, from: currentPageIndex)
        if !pageReader.isSpeaking { editMessage = String(localized: "There is no text to read from this page on. If the pages are scans, use Recognize Text first.") }
    }
}
