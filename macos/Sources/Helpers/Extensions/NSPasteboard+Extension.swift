import AppKit
import GhosttyKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Initialize a pasteboard type from a MIME type string
    init?(mimeType: String) {
        // Explicit mappings for common MIME types
        switch mimeType {
        case "text/plain":
            self = .string
            return
        default:
            break
        }

        // Try to get UTType from MIME type
        guard let utType = UTType(mimeType: mimeType) else {
            // Fallback: use the MIME type directly as identifier
            self.init(mimeType)
            return
        }

        // Use the UTType's identifier
        self.init(utType.identifier)
    }
}

extension NSPasteboard {
    /// The pasteboard to used for Ghostty selection.
    static var ghosttySelection: NSPasteboard = {
        NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
    }()

    /// Gets the contents of the pasteboard as a string following a specific set of semantics.
    /// Does these things in order:
    /// - Tries to get the absolute filesystem path of the file in the pasteboard if there is one and ensures the file path is properly escaped.
    /// - Tries to get any string from the pasteboard.
    /// - Saves image-only clipboard contents to a PNG file and returns its escaped path.
    /// If all of the above fail, returns None.
    func getOpinionatedStringContents() -> String? {
        if let urls = readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.count > 0 {
            return urls
                .map { $0.isFileURL ? Ghostty.Shell.escape($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }

        if let string = self.string(forType: .string) {
            return string
        }

        if let imagePath = saveImageContentsToFile() {
            return Ghostty.Shell.escape(imagePath)
        }

        return nil
    }

    /// The pasteboard for the Ghostty enum type.
    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch clipboard {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return Self.general

        case GHOSTTY_CLIPBOARD_SELECTION:
            return Self.ghosttySelection

        default:
            return nil
        }
    }

    private func saveImageContentsToFile() -> String? {
        if GhosttyClipboardImageCache.changeCount == changeCount,
           let path = GhosttyClipboardImageCache.path,
           FileManager.default.fileExists(atPath: path) {
            return path
        }

        guard let image = NSImage(pasteboard: self) else { return nil }
        guard let tiff = image.tiffRepresentation else { return nil }
        guard let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }

        do {
            let directory = try Self.clipboardImagesDirectory()
            let filename = "ghostty-clipboard-\(UInt64(Date().timeIntervalSince1970 * 1000)).png"
            let url = directory.appendingPathComponent(filename, isDirectory: false)
            try png.write(to: url, options: .atomic)

            GhosttyClipboardImageCache.changeCount = changeCount
            GhosttyClipboardImageCache.path = url.path
            return url.path
        } catch {
            AppDelegate.logger.warning("failed to save clipboard image: \(error.localizedDescription)")
            return nil
        }
    }

    private static func clipboardImagesDirectory() throws -> URL {
        let pictures = FileManager.default.urls(
            for: .picturesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)

        let directory = pictures.appendingPathComponent("Ghostty Clipboard", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

private enum GhosttyClipboardImageCache {
    static var changeCount: Int = -1
    static var path: String?
}
