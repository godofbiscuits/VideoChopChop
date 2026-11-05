//
//  VideoDropTests.swift
//  VideoChopChopTests
//

import AppKit
import Foundation
import Testing
@testable import VideoChopChop

/// A minimal dragging session backed by a private pasteboard, so the views' real drag methods can run.
private final class StubDraggingInfo: NSObject, NSDraggingInfo {
    nonisolated(unsafe) let draggingPasteboard: NSPasteboard
    nonisolated init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

@MainActor
struct VideoDropTests {
    private func pasteboard(with urls: [URL]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return pasteboard
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A real movie plus a copy named `.mp4`, a text file and a folder.
    private func makeFiles() async throws -> (directory: URL, mov: URL, mp4: URL, text: URL, folder: URL) {
        let directory = try scratchDirectory()
        let source = try await makeTestVideo(segments: [.solid(220, 30, 30, frames: 6)])
        let mov = directory.appendingPathComponent("clip.mov")
        let mp4 = directory.appendingPathComponent("clip.mp4")
        try FileManager.default.moveItem(at: source, to: mov)
        try FileManager.default.copyItem(at: mov, to: mp4)
        let text = directory.appendingPathComponent("notes.txt")
        try "not a video".write(to: text, atomically: true, encoding: .utf8)
        let folder = directory.appendingPathComponent("a folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (directory, mov, mp4, text, folder)
    }

    @Test func acceptsMovieAndMP4Files() async throws {
        let files = try await makeFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        #expect(VideoDrop.videoURL(from: pasteboard(with: [files.mov]))?.lastPathComponent == "clip.mov")
        #expect(VideoDrop.videoURL(from: pasteboard(with: [files.mp4]))?.lastPathComponent == "clip.mp4")
        #expect(VideoDrop.operation(for: pasteboard(with: [files.mp4])) == .copy)
    }

    @Test func refusesEverythingThatIsNotAMovie() async throws {
        let files = try await makeFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        for url in [files.text, files.folder] {
            #expect(VideoDrop.videoURL(from: pasteboard(with: [url])) == nil, "\(url.lastPathComponent)")
            #expect(VideoDrop.operation(for: pasteboard(with: [url])) == [])
        }
        #expect(VideoDrop.videoURL(from: pasteboard(with: [])) == nil)
    }

    @Test func picksTheMovieOutOfAMixedDrop() async throws {
        let files = try await makeFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let url = VideoDrop.videoURL(from: pasteboard(with: [files.text, files.folder, files.mp4]))
        #expect(url?.lastPathComponent == "clip.mp4")
    }

    @Test func timelineAcceptsADroppedMovieAndHighlightsWhileOver() async throws {
        let files = try await makeFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let timeline = SceneTimelineView(frame: NSRect(x: 0, y: 0, width: 400, height: SceneTimelineView.totalHeight))
        #expect(timeline.registeredDraggedTypes.contains(.fileURL))
        var received: URL?
        timeline.onDropVideo = { received = $0 }

        let movie = StubDraggingInfo(pasteboard: pasteboard(with: [files.mp4]))
        #expect(timeline.draggingEntered(movie) == .copy)
        #expect(timeline.isDropTargeted)
        #expect(timeline.prepareForDragOperation(movie))
        #expect(timeline.performDragOperation(movie))
        #expect(!timeline.isDropTargeted)
        #expect(received?.lastPathComponent == "clip.mp4")

        // Something that is not a movie: no-drop cursor, no highlight, and nothing is opened.
        received = nil
        let text = StubDraggingInfo(pasteboard: pasteboard(with: [files.text]))
        #expect(timeline.draggingEntered(text) == [])
        #expect(!timeline.isDropTargeted)
        #expect(!timeline.prepareForDragOperation(text))
        #expect(!timeline.performDragOperation(text))
        #expect(received == nil)

        // Dragging away clears the highlight.
        _ = timeline.draggingEntered(movie)
        timeline.draggingExited(movie)
        #expect(!timeline.isDropTargeted)
    }

    @Test func playerAcceptsADroppedMovie() async throws {
        let files = try await makeFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let player = DroppableAVPlayerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        #expect(player.registeredDraggedTypes.contains(.fileURL))
        var received: URL?
        player.onDropVideo = { received = $0 }

        let movie = StubDraggingInfo(pasteboard: pasteboard(with: [files.mov]))
        #expect(player.draggingEntered(movie) == .copy)
        #expect(player.layer?.borderWidth == 3)
        #expect(player.performDragOperation(movie))
        #expect(player.layer?.borderWidth == 0)
        #expect(received?.lastPathComponent == "clip.mov")

        received = nil
        let folder = StubDraggingInfo(pasteboard: pasteboard(with: [files.folder]))
        #expect(player.draggingEntered(folder) == [])
        #expect(player.layer?.borderWidth == 0)
        #expect(!player.performDragOperation(folder))
        #expect(received == nil)
    }

    @Test func emptyTimelineDrawsItsMessage() throws {
        func render(_ placeholder: String?) throws -> Data {
            let view = SceneTimelineView(frame: NSRect(x: 0, y: 0, width: 600, height: SceneTimelineView.totalHeight))
            view.fit(toVisibleWidth: 600)
            view.placeholder = placeholder
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            return try #require(rep.representation(using: .png, properties: [:]))
        }
        #expect(try render("Drop a video here") != render(nil), "the placeholder text should change what is drawn")
    }
}
