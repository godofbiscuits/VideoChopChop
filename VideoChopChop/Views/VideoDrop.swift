//
//  VideoDrop.swift
//  VideoChopChop
//

import AppKit
import UniformTypeIdentifiers

/// Shared drag-and-drop rules: only a movie file is accepted, so folders and other files are refused
/// (and the pointer shows the "not allowed" cursor).
@MainActor
enum VideoDrop {
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL]

    /// The first movie file on the pasteboard, if any.
    static func videoURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.movie.identifier],
        ]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first
    }

    static func operation(for pasteboard: NSPasteboard) -> NSDragOperation {
        videoURL(from: pasteboard) == nil ? [] : .copy
    }
}
