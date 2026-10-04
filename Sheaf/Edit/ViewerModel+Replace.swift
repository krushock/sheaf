import AppKit
import PDFKit
import SheafKit

/// Find and replace in the pages' own text.
extension ViewerModel {
    func showReplace() {
        isReplaceVisible = true
        replaceFocusRequests += 1
    }

    func replaceVisibilityChanged() {
        if isReplaceVisible {
            // Carry over what is already being searched for.
            if replaceQuery.isEmpty, !searchText.isEmpty { replaceQuery = searchText }
            scheduleTextSearch()
        } else {
            textSearchTask?.cancel()
            textMatches = []
            currentMatchIndex = nil
            isFindingText = false
        }
    }

    /// Looks for the query on every page, off the main thread.
    ///
    /// - Parameters:
    ///   - keepingPlace: After a change to the document, stay near the match that was current.
    ///   - revealing: Scroll to the match that ends up current, as after Replace.
    func scheduleTextSearch(keepingPlace: Bool = false, revealing: Bool = false) {
        textSearchTask?.cancel()
        let query = replaceQuery
        guard isReplaceVisible, !query.isEmpty, let sheafDocument, sheafDocument.isEditable else {
            textMatches = []
            currentMatchIndex = nil
            isFindingText = false
            return
        }
        let options = replaceOptions
        let count = pageCount
        let place = keepingPlace ? currentMatchIndex.flatMap { textMatches.indices.contains($0) ? textMatches[$0] : nil } : nil
        let revision = sheafDocument.revision
        isFindingText = true
        textSearchTask = Task { [weak self] in
            // Wait for a pause in typing.
            if !keepingPlace { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            let source = Toolbox.Source(data: sheafDocument.currentData, name: "", password: sheafDocument.password)
            let started = Date()
            let found = (try? await Toolbox.findText(source, query, options: options, pageCount: count) { Task.isCancelled }) ?? []
            // Out of date if the document changed, or another search started, meanwhile.
            guard let self, !Task.isCancelled, sheafDocument.revision == revision else { return }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "SnapshotTimings") { print("TIMING find: \(found.count) matches on \(count) pages in \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
            #endif
            self.textMatches = found
            self.isFindingText = false
            if found.isEmpty {
                self.currentMatchIndex = nil
            } else if let place {
                // The first match at or after where the last one was.
                self.currentMatchIndex = found.firstIndex { ($0.pageIndex, -($0.frames.first?.y ?? 0)) >= (place.pageIndex, -(place.frames.first?.y ?? 0)) } ?? 0
                if revealing { self.revealCurrentMatch() }
            } else {
                self.currentMatchIndex = found.firstIndex { $0.pageIndex >= self.currentPageIndex } ?? 0
                self.revealCurrentMatch()
            }
        }
    }

    var currentMatch: TextMatch? {
        currentMatchIndex.flatMap { textMatches.indices.contains($0) ? textMatches[$0] : nil }
    }

    func selectMatch(offset: Int) {
        guard !textMatches.isEmpty else { return }
        let current = currentMatchIndex ?? (offset > 0 ? -1 : 0)
        currentMatchIndex = (current + offset + textMatches.count) % textMatches.count
        revealCurrentMatch()
    }

    private func revealCurrentMatch() {
        guard let match = currentMatch, let frame = match.frames.first, let page = document?.page(at: match.pageIndex),
              let geometry = content(ofPage: match.pageIndex)?.geometry
        else { return }
        let rect = geometry.pageRect(frame).cgRect
        // Only scroll when the match is out of sight, so stepping through a page does not jump.
        let inView = pdfView.convert(rect, from: page)
        if !pdfView.bounds.insetBy(dx: 0, dy: 40).contains(inView) {
            pdfView.go(to: rect.insetBy(dx: -40, dy: -120), on: page)
        }
        pdfView.overlay.needsDisplay = true
    }

    /// Replaces the current match and moves to the next.
    func replaceCurrentMatch() {
        guard let match = currentMatch, match.isReplaceable else {
            NSSound.beep()
            return
        }
        let replacement = replacement
        let done = changeContent(String(localized: "Replace"), pageIndex: match.pageIndex) { editor in
            guard try editor.replace([match], onPageAt: match.pageIndex, with: replacement) > 0 else {
                throw SheafError.unsupported("changing this text")
            }
        }
        // On to the next match, as Replace does in every other app.
        if done { scheduleTextSearch(keepingPlace: true, revealing: true) } else { NSSound.beep() }
    }

    /// Replaces every match. Long documents take a while, so the work is done off the
    /// main thread and the result put in place as one change that Undo takes back.
    func replaceAllMatches() {
        guard let sheafDocument, !replaceQuery.isEmpty, !textMatches.isEmpty, !isFindingText else { return }
        let query = replaceQuery, replacement = replacement, options = replaceOptions
        let total = textMatches.count
        let pages = Array(Set(textMatches.filter(\.isReplaceable).map(\.pageIndex))).sorted()
        guard !pages.isEmpty else {
            editMessage = String(localized: "None of the \(total) matches could be replaced. They are in text that cannot be changed, such as text that is turned or uses a font the document only partly includes.")
            return
        }
        let source = Toolbox.Source(data: sheafDocument.currentData, name: "", password: sheafDocument.password)
        let revision = sheafDocument.revision
        isFindingText = true
        Task { [weak self] in
            let job = Task.detached(priority: .userInitiated) {
                Result { try Toolbox.replaceAll(source, query, with: replacement, options: options, pages: pages) }
            }
            let started = Date()
            let result = await job.value
            guard let self else { return }
            self.isFindingText = false
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "SnapshotTimings") {
                print("TIMING replaceAll: \(pages.count) pages in \(Int(Date().timeIntervalSince(started) * 1000)) ms, \((try? result.get().count) ?? -1) replaced of \(total)")
            }
            #endif
            // Something else changed the document meanwhile; putting this result in would undo that.
            guard sheafDocument.revision == revision else { return }
            switch result {
            case .failure(let error):
                self.editMessage = error.localizedDescription
            case .success(let outcome):
                if outcome.count > 0, sheafDocument.replaceContents(String(localized: "Replace All"), with: outcome.data, password: sheafDocument.password) {
                    self.show(sheafDocument)
                }
                if outcome.count < total {
                    let skipped = total - outcome.count
                    self.editMessage = outcome.count == 0
                        ? String(localized: "None of the \(total) matches could be replaced. They are in text that cannot be changed, such as text that is turned or uses a font the document only partly includes.")
                        : String(localized: "Replaced \(outcome.count) matches. \(skipped) more are in text that cannot be changed.")
                }
            }
        }
    }
}
