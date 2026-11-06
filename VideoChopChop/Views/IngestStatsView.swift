//
//  IngestStatsView.swift
//  VideoChopChop
//

import AppKit
import Charts
import SwiftUI

/// Statistics for an ingest, computed from the images that were written (see `IngestFolderScanner`).
struct IngestStatsView: View {
    let statistics: IngestStatistics
    let folder: URL?
    let sourceName: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Statistics").font(.title2.bold())
                Text("\(sourceName ?? "Video") — computed from the \(statistics.imageCount.formatted()) exported images")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow {
                    tile("Scenes", statistics.sceneCount.formatted())
                    tile("Avg frames / scene", statistics.averageFramesPerScene.formatted(.number.precision(.fractionLength(1))))
                    tile("Avg time / scene", "\(statistics.averageSecondsPerScene.formatted(.number.precision(.fractionLength(2)))) s")
                }
                GridRow {
                    tile("Frames in movie", statistics.frameCount.formatted())
                    tile("Images written", statistics.imageCount.formatted())
                    tile("Frame rate", "\(statistics.frameRate.formatted(.number.precision(.fractionLength(0...2)))) fps")
                }
                GridRow {
                    tile("Total size", Self.bytes(statistics.totalBytes))
                    tile("Avg size / image", Self.bytes(Int(statistics.averageBytesPerImage)))
                    tile("Image size", statistics.imageSizes.joined(separator: ", "))
                }
            }

            histogram(
                title: "Frames per scene", distribution: statistics.framesPerScene, unit: "frames",
                format: { $0.formatted(.number.precision(.fractionLength(0))) }
            )
            histogram(
                title: "Time per scene", distribution: statistics.secondsPerScene, unit: "seconds",
                format: { "\($0.formatted(.number.precision(.fractionLength(2)))) s" }
            )

            HStack {
                if let folder {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680)
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .gridColumnAlignment(.leading)
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
            .frame(height: 130)
            .accessibilityLabel("Histogram of \(title.lowercased())")
            Text("min \(format(distribution.min))  ·  median \(format(distribution.median))  ·  90th pct \(format(distribution.p90))  ·  max \(format(distribution.max))  ·  σ \(format(distribution.standardDeviation))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
