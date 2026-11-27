import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Export for AI: the open thread as clean Markdown (ThreadExport), with a
/// preview of exactly what will be handed over.
///
/// Save writes a `.md` file, or a folder with the Markdown and an `images`
/// folder when images are included. Copy puts the Markdown alone on the
/// clipboard, with images listed by name, for pasting into a chat.
struct ExportSheet: View {
    let model: AppModel
    @State private var options = ThreadExport.Options()
    @State private var saving = false
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    private var export: ThreadExport {
        var e = model.threadExport()
        e.options = options
        return e
    }

    private var imageCount: Int { export.plannedImages().count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export for AI").font(.ui(17, .semibold)).foregroundStyle(Theme.ink)
                Text("Each message once, without quoted replies, signatures, reply headers or hidden text.")
                    .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle(imageCount == 0 ? "Include images (none in this thread)" : "Include images (\(imageCount))",
                       isOn: $options.includeImages)
                    .disabled(imageCount == 0)
                Toggle("Include email addresses (otherwise people are named only)", isOn: $options.includeAddresses)
                Toggle("Keep signatures", isOn: $options.keepSignatures)
            }
            .font(.callout)
            preview
            HStack(spacing: 8) {
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle(height: 34))
                Button(copied ? "Copied" : "Copy Markdown") { copy() }.buttonStyle(QuietButtonStyle(height: 34))
                Button(saving ? "Saving…" : "Save…") { Task { await save() } }
                    .buttonStyle(AccentButtonStyle(height: 34))
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(saving)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private var preview: some View {
        ScrollView {
            Text(export.markdown(includedImages: options.includeImages ? Set(export.plannedImages().map(\.path)) : []))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(height: 300)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.line))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(export.markdown(includedImages: []), forType: .string)
        copied = true
    }

    private func save() async {
        let panel = NSSavePanel()
        panel.title = "Export for AI"
        panel.nameFieldStringValue = ThreadExport.safeFileName(ThreadExport.subjectWithoutPrefixes(model.thread.first?.subject ?? "Thread")) + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if options.includeImages, imageCount > 0 {
            panel.message = "The Markdown and its images are saved together in a folder with this name."
        }
        guard panel.runModal() == .OK, let target = panel.url else { return }
        saving = true
        defer { saving = false }
        let package = await export.build { [model] message, attachment in
            try await model.attachmentData(attachment, of: message)
        }
        do {
            let saved = try ThreadExport.write(package, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([saved])
            dismiss()
        } catch {
            Log.error("saving an export failed", error)
            model.error = "Couldn't save the export: \(error.localizedDescription)"
        }
    }
}
