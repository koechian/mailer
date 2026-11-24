import SwiftUI
import AppKit

/// Hugeicons (free set, MIT), exported to SVG by tools/export-icons.mjs and
/// drawn as template images so they take the surrounding foreground colour.
enum Icon: String, CaseIterable {
    case inbox, mail, mailOpen, compose, sent, reply, forward, drafts, star, pin, archive, trash, spam,
         search, settings, attachment, filter, copy, notification, newsletter, calendar, folder, user,
         verified, tick, close, logout, refresh, more, back, chevronDown, clock, key, lock, shield,
         file, image, plus, markUnread, people

    private static var cache: [Icon: NSImage] = [:]

    /// The bundled SVG. Inside the .app it is in Contents/Resources/Icons;
    /// under `swift run` and tests it is read from the source tree.
    var image: NSImage {
        if let cached = Self.cache[self] { return cached }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Icons/\(rawValue).svg")
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Icons/\(rawValue).svg")
        let url = [bundled, source].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        let img = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)!
        img.isTemplate = true
        Self.cache[self] = img
        return img
    }
}

struct IconView: View {
    let icon: Icon
    var size: CGFloat = 18

    init(_ icon: Icon, size: CGFloat = 18) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image(nsImage: icon.image)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
