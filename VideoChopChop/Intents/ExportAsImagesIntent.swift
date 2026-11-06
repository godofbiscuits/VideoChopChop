//
//  ExportAsImagesIntent.swift
//  VideoChopChop
//
//  "Export as Images" as an App Intent, so it can be run by Siri (voice), Shortcuts and Spotlight.
//

import AppIntents
import Foundation

/// The app's model, shared with intents (they are created by the system, not by SwiftUI).
@MainActor
enum AppContext {
    static var model: VideoModel?
}

/// Why an export couldn't start or didn't finish. Shown (and spoken) as the intent's error.
nonisolated enum ExportFailure: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case appNotReady, noVideo, busy, noScenes, noFolder, invalidHeight, invalidStep, failed(String)

    var message: String {
        switch self {
        case .appNotReady: "VideoChopChop isn't ready yet. Open the app and try again."
        case .noVideo: "There's no video open. Open a video in VideoChopChop first."
        case .busy: "VideoChopChop is still working on the video. Try again when the scan has finished."
        case .noScenes: "No scenes were found in this video, so there is nothing to export."
        case .noFolder: "Choose an export folder first: use Export as Images in the app once, then voice commands reuse that folder."
        case .invalidHeight: "The image height must be between 1 and 4320 pixels."
        case .invalidStep: "The frame step must be between 1 and 300."
        case .failed(let reason): "The export failed: \(reason)"
        }
    }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// The export itself, separate from the intent so it can be tested without the App Intents machinery.
@MainActor
enum ExportAsImagesAction {
    /// Exports the open video into the remembered export folder and returns a one-sentence summary.
    /// `height` / `frameStep` apply to this run only; nil uses the settings from the app.
    static func run(model: VideoModel, height: Int?, frameStep: Int?, defaults: UserDefaults = .standard) async throws -> String {
        if let height, !(1...4320).contains(height) { throw ExportFailure.invalidHeight }
        if let frameStep, !(1...300).contains(frameStep) { throw ExportFailure.invalidStep }
        guard model.videoURL != nil else { throw ExportFailure.noVideo }
        guard !model.isBusy else { throw ExportFailure.busy }
        guard !model.scenes.isEmpty else { throw ExportFailure.noScenes }
        // The folder from the last export in this session, else the one saved as a bookmark (see ExportDestination).
        guard let folder = model.exportFolder ?? ExportDestination.resolve(defaults: defaults) else { throw ExportFailure.noFolder }

        await model.ingest(into: folder, height: height, frameStep: frameStep)

        guard let result = model.ingestFolder, let statistics = model.ingestStatistics else {
            throw ExportFailure.failed(model.errorMessage ?? model.statusMessage ?? "unknown error")
        }
        return "Exported \(statistics.imageCount.formatted()) images in \(statistics.sceneCount) scenes to “\(result.lastPathComponent)”."
    }
}

struct ExportAsImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Export as Images"
    static let description = IntentDescription(
        "Writes every frame of the open video as a JPEG XL image, one folder per scene, into the folder you last chose in the app.",
        categoryName: "Export"
    )
    // The video and its scenes live in the running app, so the app must be open for this to work.
    static let openAppWhenRun = true

    @Parameter(title: "Image Height", description: "Vertical resolution in pixels. Leave empty to use the setting in the app.",
               inclusiveRange: (1, 4320))
    var height: Int?

    @Parameter(title: "Every Nth Frame", description: "Write every Nth frame. Leave empty to use the setting in the app.",
               inclusiveRange: (1, 300))
    var frameStep: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppContext.model else { throw ExportFailure.appNotReady }
        let summary = try await ExportAsImagesAction.run(model: model, height: height, frameStep: frameStep)
        return .result(dialog: IntentDialog("\(summary)"))
    }
}

/// The phrases Siri listens for. They work as soon as the app has been run once.
struct VideoChopChopShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ExportAsImagesIntent(),
            phrases: [
                "Export as images in \(.applicationName)",
                "Export images from \(.applicationName)",
                "\(.applicationName), export as images",
            ],
            shortTitle: "Export as Images",
            systemImageName: "photo.stack"
        )
    }
}
