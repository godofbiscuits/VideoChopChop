//
//  FrameSource.swift
//  VideoChopChop
//
//  Pull-based video decoding: callers ask for the next frame, so decoding
//  never runs ahead of analysis or export.
//

import AVFoundation
import CoreMedia
import CoreVideo

/// A decoded video frame. The pixel buffer is never mutated after delivery, so sharing it is safe.
nonisolated struct VideoFrame: @unchecked Sendable {
    let index: Int
    let time: CMTime
    let pixelBuffer: CVPixelBuffer

    var seconds: Double { time.seconds }
}

nonisolated enum FrameSourceError: Error {
    case noVideoTrack
    case cannotStartReading(String)
}

/// Streams BGRA frames from the first video track of a movie file.
///
/// `AVAssetReaderOutput.copyNextSampleBuffer()` is a *blocking* call: it waits on the media pipeline for the next
/// decoded frame. Running it on Swift concurrency's shared worker pool (one worker per core) lets a handful of
/// concurrent readers occupy every worker, starving the very tasks the media pipeline needs in order to make
/// progress (e.g. an AVAssetWriter being fed in an async loop), which is a deadlock. So this actor runs on its own
/// serial executor, a dedicated dispatch queue: the blocking wait ties up that queue's thread and nothing else.
/// (A custom executor is the one place a dispatch queue is the right tool; there is no async reader API.)
actor FrameSource {
    private let decodeQueue = DispatchSerialQueue(label: "VideoChopChop.FrameSource.decode", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { decodeQueue.asUnownedSerialExecutor() }

    nonisolated let duration: Double
    nonisolated let frameRate: Double
    /// Pixel size of the stored frames (before `preferredTransform`).
    nonisolated let size: CGSize
    nonisolated let preferredTransform: CGAffineTransform

    private let reader: AVAssetReader
    private let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
    private var nextIndex = 0

    static func open(url: URL) async throws -> FrameSource {
        try await FrameSource(url: url)
    }

    // The asset, track, reader and output are all non-Sendable, so everything is created inside this initializer.
    private init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FrameSourceError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        let (fps, size, preferredTransform) = try await track.load(.nominalFrameRate, .naturalSize, .preferredTransform)
        let frameRate = fps > 0 ? Double(fps) : 30

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        let provider = reader.outputProvider(for: output)
        do {
            try reader.start()
        } catch {
            throw FrameSourceError.cannotStartReading(error.localizedDescription)
        }
        self.reader = reader
        self.provider = provider
        self.duration = duration
        self.frameRate = frameRate
        self.size = size
        self.preferredTransform = preferredTransform
    }

    /// Returns the next frame, or nil at the end of the video.
    func next() async throws -> VideoFrame? {
        // Provider.next() wraps the blocking copyNextSampleBuffer(); run it on the dedicated decode queue, not the shared pool.
        while let sample = try await withTaskExecutorPreference(decodeQueue, operation: { try await provider.next() }) {
            guard let pixelSample = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(sample) else { continue }
            let index = nextIndex, time = pixelSample.presentationTimeStamp
            nextIndex += 1
            // VideoFrame is Sendable, which is what lets the pixel buffer leave the closure.
            return pixelSample.content.withUnsafeBuffer { VideoFrame(index: index, time: time, pixelBuffer: $0) }
        }
        if reader.status == .failed, let error = reader.error { throw error }
        return nil
    }
}
