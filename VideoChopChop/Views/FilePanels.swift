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

    static func chooseExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Export Frames"
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
