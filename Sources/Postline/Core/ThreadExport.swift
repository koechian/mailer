import Foundation

/// A thread as one clean Markdown document for an AI assistant, with its
/// images beside it if wanted.
///
/// Each message appears once, oldest first, under its sender and time, with
/// who it went to: the quoted history, signatures, reply headers and hidden
/// text are taken out (MailMarkdown, QuotedHistory). Messages are taken
/// from what the reader showed (the HTML), not from the plain-text copy an
/// email may also carry, which the reader never shows and which could say
/// something else.
///
/// People are named, not addressed, unless `includeAddresses` is on; the
/// owner's own addresses are marked "(me)". Image attachments go in an
/// `images` folder and are linked where their message is; other
/// attachments are listed by name and size only.
struct ThreadExport {

    struct Options: Equatable, Sendable {
        var includeImages = true
        var includeAddresses = false
        var keepSignatures = false
    }

    struct Image: Equatable, Sendable {
        /// Relative to the Markdown file: `images/2-1-screenshot.png`.
        let path: String
        let data: Data
    }

    struct Package: Sendable {
        let markdown: String
        let images: [Image]
    }

    /// One image attachment and the path it is saved under.
    struct PlannedImage: Sendable {
        let message: Message
        let attachment: Attachment
        let path: String
    }

    let thread: [Message]
    /// The owner's addresses, lowercased.
    let me: Set<String>
    var options = Options()
    var timeZone = TimeZone.current

    // MARK: Building

    /// The document and, with `includeImages`, every image `load` could
    /// fetch. Images it could not fetch are listed as not included.
    func build(load: @Sendable (Message, Attachment) async throws -> Data) async -> Package {
        var images: [Image] = []
        if options.includeImages {
            for item in plannedImages() {
                if let data = try? await load(item.message, item.attachment) {
                    images.append(Image(path: item.path, data: data))
                }
            }
        }
        return Package(markdown: markdown(includedImages: Set(images.map(\.path))), images: images)
    }

    func plannedImages() -> [PlannedImage] {
        var planned: [PlannedImage] = []
        for (index, message) in thread.enumerated() {
            for (number, attachment) in message.attachments.filter(Self.isImage).enumerated() {
                let path = "images/\(index + 1)-\(number + 1)-\(Self.safeFileName(attachment.filename))"
                planned.append(PlannedImage(message: message, attachment: attachment, path: path))
            }
        }
        return planned
    }

    static func isImage(_ attachment: Attachment) -> Bool {
        attachment.mimeType.lowercased().hasPrefix("image/")
    }

    // MARK: The document

    func markdown(includedImages: Set<String>) -> String {
        var parts = [header(), "---"]
        let planned = Dictionary(grouping: plannedImages(), by: { $0.message.id })
        for (index, message) in thread.enumerated() {
            parts.append(section(message, number: index + 1, images: planned[message.id] ?? [], included: includedImages))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    private func header() -> String {
        let count = thread.count == 1 ? "1 message" : "\(thread.count) messages"
        var lines = ["# \(Self.subjectWithoutPrefixes(thread.first?.subject ?? ""))", ""]
        lines.append("Email thread exported from Mailer for an AI assistant: \(count), \(dateRange()). "
            + "Quoted replies, signatures and hidden text are removed, so each message appears once, "
            + "oldest first, as its sender wrote it.")
        lines.append("")
        lines.append("**Participants:** " + participants().joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    private func section(_ m: Message, number: Int, images: [PlannedImage], included: Set<String>) -> String {
        var lines = ["## \(number). \(person(name: m.fromName, email: m.fromEmail)) — \(format(m.date, "EEE d MMM yyyy, HH:mm"))"]
        lines.append(recipients(of: m))
        lines.append("")
        lines.append(body(of: m))
        let (shown, missing) = (images.filter { included.contains($0.path) }, images.filter { !included.contains($0.path) })
        if !shown.isEmpty {
            lines.append("")
            lines += shown.map { "![\($0.attachment.filename)](\(Self.markdownPath($0.path)))" }
        }
        let others = m.attachments.filter { !Self.isImage($0) }.map(describe) + missing.map { describe($0.attachment) }
        if !others.isEmpty {
            lines.append("")
            lines.append("**Attachments (not included):** " + others.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    func body(of m: Message) -> String {
        let source = (m.bodyHTML ?? "").isEmpty
            ? m.bodyText
            : MailMarkdown.convert(m.bodyHTML ?? "", keepSignature: options.keepSignatures)
        let text = QuotedHistory.trim(source, keepSignature: options.keepSignatures)
        return text.isEmpty ? "*(No new text: this message only quotes earlier ones.)*" : text
    }

    private func recipients(of m: Message) -> String {
        var parts: [String] = []
        if !m.to.isEmpty { parts.append("**To:** " + m.to.map(person).joined(separator: ", ")) }
        if !m.cc.isEmpty { parts.append("**Cc:** " + m.cc.map(person).joined(separator: ", ")) }
        return parts.isEmpty ? "**To:** (no recipients shown)" : parts.joined(separator: " · ")
    }

    // MARK: People

    private func person(_ raw: String) -> String {
        let (name, email) = MessageParser.splitAddress(raw)
        return person(name: name, email: email)
    }

    /// "Ben Otieno", "Ben Otieno <ben@x.com>" with addresses on, the part
    /// before the @ when there is no name, and "(me)" for the owner.
    func person(name: String, email: String) -> String {
        let address = email.lowercased()
        let local = address.split(separator: "@").first.map(String.init) ?? address
        var label = name.trimmingCharacters(in: .whitespaces)
        if label.isEmpty { label = options.includeAddresses ? address : local }
        else if options.includeAddresses, !address.isEmpty { label += " <\(address)>" }
        return me.contains(address) ? label + " (me)" : label
    }

    private func participants() -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for m in thread {
            let everyone = [(m.fromName, m.fromEmail)] + (m.to + m.cc).map(MessageParser.splitAddress)
            for (name, email) in everyone where seen.insert(email.lowercased()).inserted {
                out.append(person(name: name, email: email))
            }
        }
        return out
    }

    // MARK: Formatting

    private func dateRange() -> String {
        guard let first = thread.first?.date, let last = thread.last?.date else { return "" }
        let (from, to) = (format(first, "d MMM yyyy"), format(last, "d MMM yyyy"))
        return from == to ? from : "\(from) to \(to)"
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }

    private func describe(_ a: Attachment) -> String {
        a.size > 0 ? "\(a.filename) (\(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)))" : a.filename
    }

    static func subjectWithoutPrefixes(_ subject: String) -> String {
        let s = subject.replacingOccurrences(of: #"^(\s*(re|fwd?|aw|wg|tr)\s*:\s*)+"#, with: "",
                                             options: [.regularExpression, .caseInsensitive])
        return s.isEmpty ? "(no subject)" : s
    }

    /// Letters, digits, dots, dashes and underscores; anything else a dash.
    static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return cleaned.isEmpty ? "image" : cleaned
    }

    /// Paths with spaces need angle brackets in a Markdown link.
    private static func markdownPath(_ path: String) -> String {
        path.contains(" ") ? "<\(path)>" : path
    }

    // MARK: Saving

    /// Saves the export where the save panel pointed (`…/Name.md`): that
    /// file alone when there are no images, else a folder `…/Name` holding
    /// `thread.md` and `images/`. A folder already there is never replaced;
    /// the new one gets a number. Returns what to show in Finder.
    static func write(_ package: Package, to target: URL) throws -> URL {
        let fm = FileManager.default
        guard !package.images.isEmpty else {
            try Data(package.markdown.utf8).write(to: target, options: .atomic)
            return target
        }
        let base = target.deletingPathExtension()
        var folder = base
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) \(n)")
            n += 1
        }
        try fm.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data(package.markdown.utf8).write(to: folder.appendingPathComponent("thread.md"), options: .atomic)
        for image in package.images {
            try image.data.write(to: folder.appendingPathComponent(image.path), options: .atomic)
        }
        return folder
    }
}
