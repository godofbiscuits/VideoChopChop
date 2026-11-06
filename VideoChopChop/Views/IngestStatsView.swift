//
//  IngestStatsView.swift
//  VideoChopChop
//

import AppKit
import Charts
import SwiftUI

/// Where a set of statistics came from.
enum StatisticsSource: String, CaseIterable, Identifiable {
    /// Computed from the scenes found by the scan.
    case video = "From the video"
    /// Computed from the images written by "Export as Images".
    case images = "From exported images"

    var id: String { rawValue }
}

/// Content of the Statistics window: it follows the model, so it fills in as the scan and any export finish.
struct StatisticsWindow: View {
    static let windowID = "statistics"

    let model: VideoModel
    @State private var chosen: StatisticsSource?

    /// The exported images' statistics win when they exist, unless the user picked the other set.
    private var source: StatisticsSource {
        if let chosen, statistics(for: chosen) != nil { return chosen }
        return model.ingestStatistics != nil ? .images : .video
    }

    private func statistics(for source: StatisticsSource) -> IngestStatistics? {
        source == .video ? model.sceneStatistics : model.ingestStatistics
    }

    var body: some View {
        Group {
            if let statistics = statistics(for: source) {
                IngestStatsView(
                    statistics: statistics, source: source, folder: source == .images ? model.ingestFolder : nil,
                    sourceName: model.sourceName,
                    availableSources: StatisticsSource.allCases.filter { self.statistics(for: $0) != nil },
                    selection: Binding(get: { source }, set: { chosen = $0 })
                )
            } else {
                ContentUnavailableView(
                    "No Statistics Yet", systemImage: "chart.bar",
                    description: Text(model.isAnalyzing ? "The scan is still finding scene cuts…" : "Open a video to find its scenes.")
                )
            }
        }
        .frame(minWidth: 820, minHeight: 360)
    }
}

/// Statistics for a video: scene counts and the distribution of frames and time per scene.
struct IngestStatsView: View {
    let statistics: IngestStatistics
    let source: StatisticsSource
    let folder: URL?
    let sourceName: String?
    var availableSources: [StatisticsSource] = []
    var selection: Binding<StatisticsSource>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Statistics").font(.title2.bold())
                    Text("\(sourceName ?? "Video") — \(subtitle)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if availableSources.count > 1, let selection {
                    Picker("Source", selection: selection) {
                        ForEach(availableSources) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            // Headline numbers in one row; image figures only exist once images have been written.
            HStack(alignment: .top, spacing: 32) {
                tile("Scenes", statistics.sceneCount.formatted())
                tile("Avg frames / scene", statistics.averageFramesPerScene.formatted(.number.precision(.fractionLength(1))))
                tile("Avg time / scene", "\(statistics.averageSecondsPerScene.formatted(.number.precision(.fractionLength(2)))) s")
                tile("Frames in movie", statistics.frameCount.formatted())
                tile("Frame rate", "\(statistics.frameRate.formatted(.number.precision(.fractionLength(0...2)))) fps")
                if source == .images {
                    tile("Images written", statistics.imageCount.formatted())
                    tile("Total size", Self.bytes(statistics.totalBytes))
                    tile("Avg size / image", Self.bytes(Int(statistics.averageBytesPerImage)))
                    tile("Image size", statistics.imageSizes.joined(separator: ", "))
                }
            }

            // The two histograms side by side.
            HStack(alignment: .top, spacing: 24) {
                histogram(
                    title: "Frames per scene", distribution: statistics.framesPerScene, unit: "frames",
                    format: { $0.formatted(.number.precision(.fractionLength(0))) }
                )
                histogram(
                    title: "Time per scene", distribution: statistics.secondsPerScene, unit: "seconds",
                    format: { "\($0.formatted(.number.precision(.fractionLength(2)))) s" }
                )
            }

            if let folder {
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    Spacer()
                }
            }
        }
        .padding(20)
    }

    private var subtitle: String {
        switch source {
        case .video: "computed from the \(statistics.sceneCount.formatted()) scenes found in the video (no images written yet)"
        case .images: "computed from the \(statistics.imageCount.formatted()) exported images"
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    private func histogram(
        title: String, distribution: Distribution, unit: String, format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Chart(distribution.histogram) { bin in
                // A column from zero up to the bin's count, spanning the bin's range. (A BarMark with a single
                // numeric `y` would draw a thin floating strip instead.)
                RectangleMark(
                    xStart: .value("From", bin.lower), xEnd: .value("To", bin.upper),
                    yStart: .value("Zero", 0), yEnd: .value("Scenes", bin.count)
                )
                .foregroundStyle(Color.accentColor.gradient)
            }
            .chartXAxisLabel(unit, alignment: .center)
            .chartYAxisLabel("scenes")
            .frame(minHeight: 160)
            .accessibilityLabel("Histogram of \(title.lowercased())")
            Text("min \(format(distribution.min))  ·  median \(format(distribution.median))  ·  90th pct \(format(distribution.p90))  ·  max \(format(distribution.max))  ·  σ \(format(distribution.standardDeviation))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
