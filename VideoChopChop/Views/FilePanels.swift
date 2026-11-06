//
//  FilePanels.swift
//  VideoChopChop
//

import AppKit
import UniformTypeIdentifiers

/// AppKit open panels. Used instead of SwiftUI's `.fileImporter` because only the last
/// `.fileImporter` attached to a view works, and the app needs two (video and export folder).
@MainActor
enum FilePanels {
    static func chooseVideo() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Video"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static let lastIngestFolderKey = "lastIngestParentFolder"

    /// Picks the folder an ingest's movie folder will be created in. The panel opens where you last chose.
    static func chooseIngestFolder(defaults: UserDefaults = .standard) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose where to put the exported images"
        panel.message = "A folder named after the movie will be created inside the one you choose."
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let last = defaults.string(forKey: lastIngestFolderKey) {
            panel.directoryURL = URL(fileURLWithPath: last, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        defaults.set(url.path, forKey: lastIngestFolderKey)
        ExportDestination.remember(url, defaults: defaults)
        return url
    }
}
