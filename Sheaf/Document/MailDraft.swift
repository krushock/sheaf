import Foundation

/// Writes a reply to a message as a draft file that Mail opens ready to send.
///
/// Mail quotes the original in a reply it starts itself, but a reply started by script
/// loses that quote as soon as the script adds an attachment. A draft file does not
/// have the problem: Mail opens a message marked as unsent in a window for writing,
/// with whatever body and attachments the file has. So the reply is written out here in
/// full: addressed to the sender, with the original's own formatted text inside the
/// kind of block Mail shows as a quote, the pictures that text uses, the headers that
/// tie it to the original, and the document attached.
nonisolated enum MailDraft {
    /// One part of a message: its headers and what follows them.
    struct Part {
        var headers: [(name: String, value: String)] = []
        var body = ""
        /// The part exactly as the message has it, headers and all.
        var raw = ""

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        /// The kind of content, in lower case, without its parameters.
        var contentType: String {
            (header("Content-Type") ?? "text/plain").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        }

        /// A parameter of a header, such as the boundary or the character set of the content type.
        func parameter(_ name: String, of header: String = "Content-Type") -> String? {
            guard let value = self.header(header) else { return nil }
            for piece in value.split(separator: ";").dropFirst() {
                let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, pair[0].caseInsensitiveCompare(name) == .orderedSame {
                    return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            return nil
        }

        var isAttachment: Bool {
            header("Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        }
    }

    /// Reads a message, or a part of one, into its headers and body. Line ends are plain line feeds by now.
    static func part(_ text: String) -> Part {
        var result = Part(raw: text)
        let split = text.range(of: "\n\n")
        let head = split.map { String(text[..<$0.lowerBound]) } ?? text
        result.body = split.map { String(text[$0.upperBound...]) } ?? ""
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", !result.headers.isEmpty {
                // A long header goes on over several lines, each starting with a space.
                result.headers[result.headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                result.headers.append((String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            }
        }
        return result
    }

    /// The parts of a message that are content themselves, however deeply they are nested.
    static func leaves(of part: Part, depth: Int = 0) -> [Part] {
        guard part.contentType.hasPrefix("multipart/"), let boundary = part.parameter("boundary"), depth < 12 else { return [part] }
        var result: [Part] = []
        // Everything between two boundary lines is a part. What comes before the first is not.
        for piece in ("\n" + part.body).components(separatedBy: "\n--" + boundary).dropFirst() {
            if piece.hasPrefix("--") { break }
            guard let lineEnd = piece.firstIndex(of: "\n") else { continue }
            result.append(contentsOf: leaves(of: self.part(String(piece[piece.index(after: lineEnd)...])), depth: depth + 1))
        }
        return result
    }

    /// The text of a part, with its transfer encoding undone and its characters read in its own character set.
    static func text(of part: Part) -> String {
        let data: Data
        switch part.header("Content-Transfer-Encoding")?.lowercased() {
        case "base64":
            data = Data(base64Encoded: part.body, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            var bytes: [UInt8] = []
            let source = Array(part.body.utf8)
            var index = 0
            while index < source.count {
                let byte = source[index]
                if byte == UInt8(ascii: "="), index + 1 < source.count, source[index + 1] == UInt8(ascii: "\n") {
                    // A line broken only to keep it short.
                    index += 2
                } else if byte == UInt8(ascii: "="), index + 2 < source.count,
                          let value = UInt8(String(decoding: source[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                    bytes.append(value)
                    index += 3
                } else {
                    bytes.append(byte)
                    index += 1
                }
            }
            data = Data(bytes)
        default:
            return part.body
        }
        var encoding = String.Encoding.utf8
        if let name = part.parameter("charset") {
            let known = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if known != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(known)) }
        }
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// What to put inside the quote: the message's formatted text when it has one, with
    /// the styles it defines, or its plain text made into lines.
    static func quotedHTML(from parts: [Part]) -> String {
        if let rich = parts.first(where: { $0.contentType == "text/html" && !$0.isAttachment }) {
            let html = text(of: rich)
            let lower = html.lowercased()
            var inner = html
            var styles = ""
            if let open = lower.range(of: "<body"), let openEnd = lower[open.upperBound...].firstIndex(of: ">") {
                let close = lower.range(of: "</body", options: .backwards)?.lowerBound ?? lower.endIndex
                if openEnd < close { inner = String(html[html.index(after: openEnd)..<close]) }
                // Styles kept in the head apply to the text all the same.
                var search = lower.startIndex..<open.lowerBound
                while let start = lower.range(of: "<style", range: search), let end = lower.range(of: "</style>", range: start.upperBound..<open.lowerBound) {
                    styles += html[start.lowerBound..<end.upperBound]
                    search = end.upperBound..<open.lowerBound
                }
            }
            return styles + inner
        }
        if let plain = parts.first(where: { $0.contentType == "text/plain" && !$0.isAttachment }) {
            return text(of: plain).split(separator: "\n", omittingEmptySubsequences: false).map { "<div>\(escaped(String($0)))<br></div>" }.joined()
        }
        return ""
    }

    private static func lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
    }

    /// When a message was sent, from its `Date` line.
    static func date(ofSource source: String) -> Date? {
        guard var text = part(source.replacingOccurrences(of: "\r\n", with: "\n")).header("Date") else { return nil }
        // A zone's name in brackets may follow the offset: "+0100 (WEST)".
        if let bracket = text.firstIndex(of: "(") { text = String(text[..<bracket]) }
        text = text.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// A reply to a message, as a file Mail opens as a draft.
    ///
    /// - Parameters:
    ///   - source: The original message as it was sent, headers and all.
    ///   - subject: The original's subject as it reads, to tell whether it is a reply already.
    ///   - heading: The line over the quote, saying who wrote it and when.
    ///   - attachment: The document to attach, and the name to give it.
    static func reply(toSource source: String, subject: String, heading: String, attachment: Data, named name: String) -> Data {
        let message = part(source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        let parts = leaves(of: message)
        let quote = quotedHTML(from: parts)
        // Pictures the text shows in place are carried along, exactly as they are. Other
        // attachments are not: a reply does not send them back.
        let pictures = parts.filter { part in
            guard part.contentType.hasPrefix("image/"), let id = part.header("Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) else { return false }
            return !id.isEmpty && quote.contains("cid:\(id)")
        }

        var headers = ["X-Unsent: 1"]
        if let to = message.header("Reply-To") ?? message.header("From") { headers.append("To: \(to)") }
        let original = message.header("Subject") ?? ""
        headers.append("Subject: " + (subject.lowercased().hasPrefix("re:") ? original : "Re: \(original)"))
        if let id = message.header("Message-ID") ?? message.header("Message-Id") {
            // What ties the reply to its conversation for every mail app.
            headers.append("In-Reply-To: \(id)")
            headers.append("References: " + [message.header("References"), id].compactMap(\.self).joined(separator: " "))
        }
        headers.append("MIME-Version: 1.0")

        let html = """
        <html><head><meta http-equiv="content-type" content="text/html; charset=utf-8"></head><body><div><br></div><div><br></div>\
        <blockquote type="cite"><div>\(escaped(heading))</div><br>\(quote)</blockquote></body></html>
        """
        let outer = "sheaf-reply-\(UUID().uuidString)", inner = "sheaf-body-\(UUID().uuidString)"
        var body = "--\(outer)\n"
        let text = "Content-Type: text/html; charset=\"utf-8\"\nContent-Transfer-Encoding: base64\n\n\(lines(Data(html.utf8)))\n"
        if pictures.isEmpty {
            body += text
        } else {
            body += "Content-Type: multipart/related; boundary=\"\(inner)\"; type=\"text/html\"\n\n--\(inner)\n" + text
            for picture in pictures { body += "--\(inner)\n" + picture.raw.trimmingCharacters(in: .newlines) + "\n" }
            body += "--\(inner)--\n"
        }
        // A name with letters outside ASCII is written the two ways mail apps look for it.
        let encodedName = "=?UTF-8?B?\(Data(name.utf8).base64EncodedString())?="
        let percentName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? "document.pdf"
        body += """
        --\(outer)
        Content-Type: application/pdf; name="\(encodedName)"
        Content-Disposition: attachment; filename*=UTF-8''\(percentName)
        Content-Transfer-Encoding: base64

        \(lines(attachment))
        --\(outer)--

        """
        let whole = headers.joined(separator: "\n") + "\nContent-Type: multipart/mixed; boundary=\"\(outer)\"\n\n" + body
        return Data(whole.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }
}
