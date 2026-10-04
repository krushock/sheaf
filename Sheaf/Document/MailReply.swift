import AppKit
import ObjectiveC
import OSLog
import UniformTypeIdentifiers

/// Where a document that was opened from a message in Mail came from.
nonisolated struct MailOrigin: Equatable, Sendable {
    var senderName: String?
    var senderAddress: String?
    var subject: String?
    /// The name the attachment had. `nil` when the file read was a copy under another name.
    var fileName: String?

    /// What to call the sender on a button: the first name, or the address.
    var shortName: String? {
        if let name = senderName?.split(separator: " ").first.map(String.init), !name.isEmpty { return name }
        return senderAddress
    }

    /// Reads where a file came from. `nil` unless it came out of Mail.
    ///
    /// Mail keeps the attachments it opens in a folder of its own, and notes on a file
    /// who sent it in two places: the "where from" attribute (sender, subject, a link to
    /// the message) and the quarantine record the system keeps for downloaded files.
    init?(fileURL: URL) {
        let path = fileURL.path(percentEncoded: false)
        // An untitled copy is read from the app's own folder of unsaved documents.
        fileName = path.contains("/Autosave Information/") ? nil : fileURL.lastPathComponent

        var entries: [String] = []
        let attribute = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(path, attribute, nil, 0, 0, 0)
        if size > 0 {
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, 0) }
            if read == size, let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] { entries = list }
        }
        let quarantine = (try? fileURL.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties ?? [:]
        func quarantined(_ key: String) -> String? {
            (quarantine[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (quarantine[key] as? URL)?.absoluteString
        }

        let hasMessageLink = entries.contains { $0.hasPrefix("message:") } || quarantined("LSQuarantineOriginURL")?.hasPrefix("message:") == true
        let isInMailFolder = path.contains("/com.apple.mail/") || path.contains("/Mail Downloads/")
        let isMailsDownload = quarantined("LSQuarantineType") == "LSQuarantineTypeEmail"
            || quarantined("LSQuarantineAgentBundleIdentifier") == "com.apple.mail"
        guard hasMessageLink || isInMailFolder || isMailsDownload else { return nil }

        for entry in entries where !entry.hasPrefix("message:") {
            if senderAddress == nil, entry.contains("@") {
                // "Name <address>" or the address alone.
                if let open = entry.lastIndex(of: "<"), let close = entry.lastIndex(of: ">"), open < close {
                    senderAddress = String(entry[entry.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                    let name = entry[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                    senderName = name.isEmpty ? nil : name
                } else {
                    senderAddress = entry.trimmingCharacters(in: .whitespaces)
                }
            } else if subject == nil, !entry.isEmpty {
                subject = entry
            }
        }
        if senderAddress == nil { senderAddress = quarantined("LSQuarantineSenderAddress") }
        if senderName == nil { senderName = quarantined("LSQuarantineSenderName") }
    }
}

/// Sending a document that came from Mail back, the way Preview offers to when such a
/// document is saved or closed after changes.
///
/// Sheaf opens a new message in Mail with the document attached. For a reply it is
/// addressed to the sender, with the subject of the message it came in when that is
/// known. It is not threaded to that message the way a reply written in Mail is: an app
/// in the sandbox may hand Mail a new message, not reach into the mailbox.
///
/// Mail's attachments open as untitled copies, with no file of their own. So where a
/// document was read from is noted as it is read, and kept with the document.
enum MailReply {
    private final class Note: NSObject {
        let origin: MailOrigin
        init(_ origin: MailOrigin) { self.origin = origin }
    }

    nonisolated private static let logger = Logger(subsystem: "com.valeryburtsev.Sheaf", category: "mail")
    nonisolated(unsafe) private static var originKey = 0
    nonisolated(unsafe) private static var sentKey = 0

    nonisolated static func origin(of document: NSDocument) -> MailOrigin? {
        (objc_getAssociatedObject(document, &originKey) as? Note)?.origin
    }

    static var canCompose: Bool { NSSharingService(named: .composeEmail) != nil }

    // MARK: Asking Mail

    /// A message in Mail that has the document as an attachment.
    struct Message: Equatable {
        var id: String
        var senderName: String?
        var senderAddress: String?
        var subject: String
        /// The sender as Mail writes it, name and address.
        var sender = ""
        /// When it arrived, as Mail writes dates.
        var received = ""

        var shortName: String? {
            if let name = senderName?.split(separator: " ").first.map(String.init), !name.isEmpty { return name }
            return senderAddress
        }
    }

    private static var isMailRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
    }

    /// Automated runs never talk to Mail: it is the person's own mailbox.
    private static var isAutomated: Bool {
        UserDefaults.standard.double(forKey: "SnapshotWindows") > 0 || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Runs a script that talks to Mail. macOS asks the person, the first time, whether
    /// Sheaf may control Mail; without that, this gives `nil`.
    private static func run(_ source: String) -> String? {
        guard !isAutomated else { return nil }
        var failure: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&failure)
        if let failure { logger.notice("Mail did not answer: \(failure[NSAppleScript.errorNumber] as? Int ?? 0, privacy: .public)") }
        return failure == nil ? result?.stringValue : nil
    }

    /// The text as a string in a script.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Reads what the script below hands back: a line for each message, with its
    /// number, sender, subject and the names of its attachments.
    static func messages(from listing: String) -> [(message: Message, attachments: [String])] {
        listing.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, !fields[0].isEmpty else { return nil }
            var message = Message(id: fields[0], subject: fields[2])
            let sender = fields[1]
            message.sender = sender
            if fields.count > 4 { message.received = fields[4] }
            if let open = sender.lastIndex(of: "<"), let close = sender.lastIndex(of: ">"), open < close {
                message.senderAddress = String(sender[sender.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                let name = sender[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                message.senderName = name.isEmpty ? nil : name
            } else if sender.contains("@") {
                message.senderAddress = sender.trimmingCharacters(in: .whitespaces)
            }
            return (message, fields[3].split(separator: "\u{1F}").map(String.init))
        }
    }

    /// The message selected in Mail that an attachment of this name came with.
    ///
    /// The file Mail hands over says nothing about its message that an app in the
    /// sandbox can read, so Mail is asked. The message an attachment was just opened
    /// from is, as a rule, still the one selected.
    static func selectedMessage(withAttachment name: String) -> Message? {
        guard isMailRunning else { return nil }
        let listing = run("""
        tell application "Mail"
            set found to ""
            repeat with candidate in (get selection)
                set names to ""
                repeat with part in mail attachments of candidate
                    set names to names & (name of part) & (character id 31)
                end repeat
                set found to found & (message id of candidate) & (character id 9) & (sender of candidate) & (character id 9) & (subject of candidate) & (character id 9) & names & (character id 9) & ((date received of candidate) as string) & (character id 10)
            end repeat
            return found
        end tell
        """)
        // Names are compared as the same letters, however accents are written down.
        let wanted = name.precomposedStringWithCanonicalMapping
        return messages(from: listing ?? "").first { entry in
            entry.attachments.contains { $0.precomposedStringWithCanonicalMapping == wanted }
        }?.message
    }

    /// Opens a reply to a message in Mail, with a document attached and the original quoted.
    ///
    /// A reply that Mail starts by script loses its quoted text as soon as the script
    /// attaches anything: the script cannot see the quote, and Mail writes the body
    /// again from what the script can see. So the reply is written here, whole, as a
    /// draft file (see `MailDraft`), from the original message as Mail hands it over,
    /// and Mail is asked to open that. It opens as a message being written, to send or
    /// to change first.
    private static func reply(to message: Message, attaching attachment: Data, named name: String, in folder: URL) -> Bool {
        guard let mail = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail"),
              let source = run("""
              tell application "Mail"
                  set wanted to \(quoted(message.id))
                  repeat with candidate in (get selection)
                      if (message id of candidate) is wanted then return source of candidate
                  end repeat
                  return ""
              end tell
              """), !source.isEmpty
        else { return false }
        let draft = MailDraft.reply(toSource: source, subject: message.subject, heading: heading(for: message, source: source), attachment: attachment, named: name)
        return open(draft, in: folder, with: mail)
    }

    /// The line above the quoted message, worded the way Mail words it.
    static func heading(for message: Message, source: String) -> String {
        guard let date = MailDraft.date(ofSource: source) else {
            return message.received.isEmpty
                ? String(localized: "\(message.sender) wrote:")
                : String(localized: "On \(message.received), \(message.sender) wrote:")
        }
        let day = date.formatted(.dateTime.day().month(.abbreviated).year())
        let time = date.formatted(.dateTime.hour().minute())
        return String(localized: "On \(day), at \(time), \(message.sender) wrote:")
    }

    /// Hands a draft to Mail, which opens it as a message being written.
    @discardableResult
    static func open(_ draft: Data, in folder: URL, with mail: URL) -> Bool {
        let fileURL = folder.appendingPathComponent("Reply.eml")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try draft.write(to: fileURL)
        } catch {
            return false
        }
        NSWorkspace.shared.open([fileURL], withApplicationAt: mail, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { logger.error("Mail did not open the reply: \(error.localizedDescription, privacy: .public)") }
        }
        return true
    }

    /// Opens a message with a document attached, as it is now, saved or not. Nothing
    /// is sent until the person sends it.
    ///
    /// - Parameters:
    ///   - message: The message in Mail to reply to, when it was found there.
    ///   - origin: Who to address a new message to when there is no message to reply to.
    static func compose(for viewer: ViewerModel, replyingTo message: Message? = nil, addressedLike origin: MailOrigin? = nil) {
        guard let data = viewer.sheafDocument?.currentData else { return }
        // A copy under the attachment's own name, for Mail to pick up.
        let name = attachmentName(for: viewer)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Reply-\(UUID().uuidString)", isDirectory: true)
        let fileURL = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: fileURL)
        } catch {
            viewer.window?.presentError(error)
            return
        }
        defer {
            if let document = viewer.window?.windowController?.document as? NSDocument {
                objc_setAssociatedObject(document, &sentKey, NSNumber(value: viewer.sheafDocument?.revision ?? 0), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
        if let message, reply(to: message, attaching: data, named: name, in: folder) { return }

        // A new message: to the sender when one is known, about the same subject.
        guard let service = NSSharingService(named: .composeEmail) else { return }
        let address = message?.senderAddress ?? origin?.senderAddress
        let subject = message?.subject ?? origin?.subject
        if let address { service.recipients = [address] }
        if let subject, !subject.isEmpty {
            service.subject = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
        }
        guard service.canPerform(withItems: [fileURL]) else { return }
        service.perform(withItems: [fileURL])
    }

    /// What to call the document in the message: the name the attachment came with.
    static func attachmentName(for viewer: ViewerModel) -> String {
        if let name = viewer.mailOrigin?.fileName { return name }
        // An untitled copy is titled "Untitled (the attachment's name)".
        var title = viewer.documentName
        if title.hasSuffix(")"), let open = title.firstIndex(of: "(") {
            let inner = String(title[title.index(after: open)...].dropLast())
            if !inner.isEmpty { title = inner }
        }
        // The copy is called "name copy"; the attachment was just "name".
        if title.hasSuffix(" copy") { title = String(title.dropLast(5)) }
        return title.lowercased().hasSuffix(".pdf") ? title : title + ".pdf"
    }

    /// Whether the document, as it is now, was already handed to Mail.
    private static func wasSent(_ document: NSDocument, at revision: Int) -> Bool {
        (objc_getAssociatedObject(document, &sentKey) as? NSNumber)?.intValue == revision
    }

    // MARK: Hooks on the document class

    /// Notes, as a document is read from a file, whether the file came from Mail.
    static func overrideReading(in kind: AnyClass) {
        let selector = #selector(NSDocument.read(from:ofType:) as (NSDocument) -> (URL, String) throws -> Void)
        SavePanelOptions.override(selector, in: kind) { original in
            typealias Original = @convention(c) (NSDocument, Selector, NSURL, NSString, NSErrorPointer) -> Bool
            let block: @convention(block) (NSDocument, NSURL, NSString, NSErrorPointer) -> Bool = { document, url, type, error in
                // A later read, of a copy the app made itself, does not wipe what the first one found.
                let origin = MailOrigin(fileURL: url as URL)
                if let origin {
                    objc_setAssociatedObject(document, &originKey, Note(origin), .OBJC_ASSOCIATION_RETAIN)
                }
                // What kind of place the file was read from, without its name or who sent it,
                // for finding out why a file from Mail was not recognised:
                //   /usr/bin/log show --last 5m --info --predicate 'subsystem == "com.valeryburtsev.Sheaf"'
                let path = (url as URL).path(percentEncoded: false)
                let place = path.contains("/com.apple.mail/") ? "Mail's folder" : path.contains("/Autosave Information/") ? "an unsaved copy" : "elsewhere"
                let quarantine = (try? (url as URL).resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties ?? [:]
                logger.notice("Read a document from \(place, privacy: .public): from Mail \(origin != nil, privacy: .public), sender known \(origin?.senderAddress != nil, privacy: .public), where-from attribute \(getxattr(path, "com.apple.metadata:kMDItemWhereFroms", nil, 0, 0, 0) > 0, privacy: .public), quarantine keys \(quarantine.keys.sorted().joined(separator: " "), privacy: .public), kind \(quarantine["LSQuarantineType"] as? String ?? "none", privacy: .public)")
                return unsafeBitCast(original, to: Original.self)(document, selector, url, type, error)
            }
            return block
        }
    }

    /// Tells whoever started a save or a close how it went, the way NSDocument does.
    private static func answer(_ delegate: AnyObject?, _ selector: Selector?, _ document: NSDocument, _ value: Bool, _ context: UnsafeMutableRawPointer?) {
        guard let delegate, let selector, let method = class_getInstanceMethod(type(of: delegate), selector) else { return }
        typealias Answer = @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(method_getImplementation(method), to: Answer.self)(delegate, selector, document, value, context)
    }

    /// Save on a copy of a Mail attachment asks first whether to send it back.
    ///
    /// The Save command itself is where this is caught. The method AppKit documents for
    /// showing the save panel is not the one it goes through for these documents.
    static func overrideSavePanel(in kind: AnyClass) {
        let selector = #selector(NSDocument.save(_:))
        SavePanelOptions.override(selector, in: kind) { original in
            typealias Original = @convention(c) (NSDocument, Selector, AnyObject?) -> Void
            let block: @convention(block) (NSDocument, AnyObject?) -> Void = { document, sender in
                nonisolated(unsafe) let document = document, sender = sender
                let proceed: @MainActor () -> Void = { unsafeBitCast(original, to: Original.self)(document, selector, sender) }
                MainActor.assumeIsolated {
                    // Only for a document that has no file yet, where Save would ask for one.
                    guard document.fileURL == nil else { return proceed() }
                    offer(for: document, closing: false, proceed: proceed, cancel: {})
                }
            }
            return block
        }
    }

    /// Closing a changed document that came from Mail asks first whether to send it back.
    static func overrideClosing(in kind: AnyClass) {
        let selector = #selector(NSDocument.canClose(withDelegate:shouldClose:contextInfo:))
        SavePanelOptions.override(selector, in: kind) { original in
            typealias Original = @convention(c) (NSDocument, Selector, AnyObject, Selector?, UnsafeMutableRawPointer?) -> Void
            let block: @convention(block) (NSDocument, AnyObject, Selector?, UnsafeMutableRawPointer?) -> Void = { document, delegate, shouldClose, context in
                nonisolated(unsafe) let document = document, delegate = delegate, context = context
                let proceed: @MainActor () -> Void = { unsafeBitCast(original, to: Original.self)(document, selector, delegate, shouldClose, context) }
                let cancel: @MainActor () -> Void = { answer(delegate, shouldClose, document, false, context) }
                MainActor.assumeIsolated { offer(for: document, closing: true, proceed: proceed, cancel: cancel) }
            }
            return block
        }
    }

    /// Asks, for a changed document that came from Mail, whether to send it back.
    ///
    /// - Parameters:
    ///   - closing: Whether the window is being closed, or the document saved.
    ///   - proceed: Goes on with the close or the save as if nothing had been asked.
    ///   - cancel: Calls the close or the save off.
    private static func offer(for document: NSDocument, closing: Bool, proceed: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void) {
        guard canCompose, let viewer = ViewerModel.viewer(of: document), let window = viewer.window, window.attachedSheet == nil,
              let sheafDocument = viewer.sheafDocument, sheafDocument.revision > 0, !wasSent(document, at: sheafDocument.revision),
              let origin = viewer.mailOrigin
        else { return proceed() }
        let name = (attachmentName(for: viewer) as NSString).deletingPathExtension
        // The message it came with, when Mail still has it selected. Failing that, who
        // the file itself says sent it, which Mail's own copies do not say.
        let message = selectedMessage(withAttachment: attachmentName(for: viewer))
        let sender = message?.shortName ?? (origin.senderAddress != nil ? origin.shortName : nil)
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(name)” came from Mail and has been changed. Send it back?")
        alert.informativeText = String(localized: "A message opens in Mail with the changed document attached. Nothing is sent until you send it.")
        if let sender { alert.addButton(withTitle: String(localized: "Reply to \(sender)…")) }
        alert.addButton(withTitle: String(localized: "New Mail Message"))
        alert.addButton(withTitle: closing ? String(localized: "Close") : String(localized: "Save…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            let choice = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + (sender != nil ? 0 : 1)
            switch choice {
            case 0, 1:
                if choice == 0 {
                    compose(for: viewer, replyingTo: message, addressedLike: origin)
                } else {
                    compose(for: viewer)
                }
                // The message is on its way to being written; the document stays as it
                // is, open, for whatever comes next.
                cancel()
            case 2: proceed()
            default: cancel()
            }
        }
    }
}

extension ViewerModel {
    /// The document's file, when it has one.
    var documentFileURL: URL? {
        (window?.windowController?.document as? NSDocument)?.fileURL
    }

    /// Looks again at whether the document came from a message in Mail, and from whom.
    func refreshMailOrigin() {
        let document = window?.windowController?.document as? NSDocument
        let origin = document.flatMap(MailReply.origin(of:)) ?? document?.fileURL.flatMap(MailOrigin.init(fileURL:))
        if origin != mailOrigin { mailOrigin = origin }
    }

    /// Starts a reply to the message the document came with, with the document attached.
    func replyInMail() {
        guard let origin = mailOrigin else { return }
        let message = MailReply.selectedMessage(withAttachment: MailReply.attachmentName(for: self))
        guard message != nil || origin.senderAddress != nil else {
            // Mail has another message selected by now, or may not be asked.
            let alert = NSAlert()
            alert.messageText = String(localized: "The message this document came with was not found in Mail.")
            alert.informativeText = String(localized: "Select the message in Mail and try again. If macOS asked whether Sheaf may control Mail and the answer was no, allow it in System Settings under Privacy & Security, Automation.")
            alert.addButton(withTitle: String(localized: "New Mail Message"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { MailReply.compose(for: self) }
            return
        }
        MailReply.compose(for: self, replyingTo: message, addressedLike: origin)
    }
}
