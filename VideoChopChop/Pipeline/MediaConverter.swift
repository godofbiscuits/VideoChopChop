//
//  MediaConverter.swift
//  VideoChopChop
//
//  AVFoundation can't read Matroska (MKV) or WebM. On import, such files are rewrapped to MP4 with a
//  small bundled ffmpeg helper: video and audio are copied untouched where Apple's frameworks support
//  the codec, and re-encoded (hardware HEVC / AAC) only where they don't. Everything downstream
//  (playback, thumbnails, filters, export) then works on the converted file as usual.
//

import AVFoundation
import CryptoKit
import Foundation

nonisolated enum ConversionError: LocalizedError, Equatable {
    case helperMissing
    case couldNotRead(String)
    case failed(status: Int32, log: String)
    case outputUnreadable

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            "This video's format can't be opened by macOS directly, and the bundled converter isn't available. Run Scripts/build-ffmpeg.sh and rebuild the app."
        case .couldNotRead(let log):
            "The converter couldn't read this file. \(log)"
        case .failed(let status, let log):
            "Conversion failed (exit \(status)). \(log)"
        case .outputUnreadable:
            "The file was converted, but macOS still can't play the result (its video codec may not be supported on this Mac)."
        }
    }
}

/// What ffmpeg reports about a file's streams.
nonisolated struct MediaProbe: Sendable, Equatable {
    var videoCodec: String?
    var audioCodecs: [String] = []
    var duration: Double?

    /// Parses the stream listing that `ffmpeg -i <file>` prints to stderr.
    static func parse(_ banner: String) -> MediaProbe {
        var probe = MediaProbe()
        for line in banner.split(separator: "\n") {
            let text = String(line)
            if let match = text.firstMatch(of: /Duration: (\d+):(\d+):(\d+(?:\.\d+)?)/),
               let h = Double(match.1), let m = Double(match.2), let s = Double(match.3) {
                probe.duration = h * 3600 + m * 60 + s
            } else if let match = text.firstMatch(of: /Stream #\d+:\d+.*?: (Video|Audio): ([A-Za-z0-9_]+)/) {
                if match.1 == "Video" {
                    if probe.videoCodec == nil { probe.videoCodec = String(match.2) }
                } else {
                    probe.audioCodecs.append(String(match.2))
                }
            }
        }
        return probe
    }
}

/// How to bring a probed file into an MP4 that AVFoundation can play.
nonisolated struct ConversionPlan: Sendable, Equatable {
    /// Codecs that can go into MP4 and play in AVFoundation unchanged.
    static let copyableVideo: Set<String> = ["h264", "hevc", "av1"]
    static let copyableAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac"]

    let copyVideo: Bool
    let copyAudio: Bool
    let videoCodec: String?

    init(probe: MediaProbe) {
        videoCodec = probe.videoCodec
        copyVideo = probe.videoCodec.map(Self.copyableVideo.contains) ?? true
        // One -c:a applies to every audio track, so copy only if all of them can be copied.
        copyAudio = probe.audioCodecs.allSatisfy(Self.copyableAudio.contains)
    }

    var isLossless: Bool { copyVideo && copyAudio }

    func arguments(input: URL, output: URL) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-y", "-fflags", "+genpts", "-i", input.path]
        // First video stream, every audio stream; subtitles, data and attachments are dropped.
        args += ["-map", "0:v:0", "-map", "0:a?", "-sn", "-dn", "-map_chapters", "-1"]
        if copyVideo {
            args += ["-c:v", "copy"]
            if videoCodec == "hevc" { args += ["-tag:v", "hvc1"] }   // the tag AVFoundation expects for HEVC in MP4
            if videoCodec == "av1" { args += ["-tag:v", "av01"] }
        } else {
            args += ["-c:v", "hevc_videotoolbox", "-q:v", "65", "-tag:v", "hvc1"]
        }
        args += copyAudio ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
        args += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output.path]
        return args
    }
}

actor MediaConverter {
    /// The bundled ffmpeg helper, if the app was built with it (Scripts/build-ffmpeg.sh).
    nonisolated static var helperURL: URL? {
        Bundle(for: MPSPass.self).url(forResource: "ffmpeg", withExtension: nil)
    }

    nonisolated static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Converted", isDirectory: true)
    }

    private let cacheDirectory: URL

    init(cacheDirectory: URL = MediaConverter.cacheDirectory) {
        self.cacheDirectory = cacheDirectory
    }

    /// Returns a URL AVFoundation can open: the original if it already can, otherwise a converted MP4
    /// (cached, so reopening the same file is instant).
    func prepare(_ url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if await Self.avFoundationCanRead(url) { return url }
        guard let helper = Self.helperURL else { throw ConversionError.helperMissing }

        let directory = cacheDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(Self.cacheName(for: url)).appendingPathExtension("mp4")
        if await Self.avFoundationCanRead(output) { return output }

        let probeRun = try await Self.run(helper, arguments: ["-hide_banner", "-i", url.path])
        let probe = MediaProbe.parse(probeRun.log)   // ffmpeg exits 1 here (no output file given); the listing is what matters
        guard probe.videoCodec != nil else { throw ConversionError.couldNotRead(Self.tail(probeRun.log)) }

        let partial = directory.appendingPathComponent(output.deletingPathExtension().lastPathComponent + ".partial.mp4")
        try? FileManager.default.removeItem(at: partial)
        let plan = ConversionPlan(probe: probe)
        let duration = probe.duration
        let result: (status: Int32, log: String)
        do {
            result = try await Self.run(helper, arguments: plan.arguments(input: url, output: partial)) { line in
                // "-progress pipe:1" prints key=value lines; out_time_us is the output position in microseconds.
                guard let duration, duration > 0, line.hasPrefix("out_time_us="),
                      let microseconds = Double(line.dropFirst("out_time_us=".count)) else { return }
                progress?(min(max(microseconds / 1_000_000 / duration, 0), 1))
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw ConversionError.failed(status: result.status, log: Self.tail(result.log))
        }

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
        guard await Self.avFoundationCanRead(output) else {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.outputUnreadable
        }
        progress?(1)
        return output
    }

    // MARK: Helpers

    nonisolated static func avFoundationCanRead(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return false }
        return (try? await asset.load(.isPlayable)) ?? false
    }

    /// Stable cache key: changes if the source file is replaced or edited.
    nonisolated static func cacheName(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func tail(_ log: String, lines: Int = 6) -> String {
        log.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    /// Runs the helper to completion. Stdout is delivered line by line; stderr is collected as the log.
    /// Cancelling the calling task terminates the process.
    private nonisolated static func run(
        _ executable: URL, arguments: [String], onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> (status: Int32, log: String) {
        let box = ProcessBox()
        box.process.executableURL = executable
        box.process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        box.process.standardOutput = stdout
        box.process.standardError = stderr
        box.process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let finished = AsyncStream<Void> { continuation in
                box.process.terminationHandler = { _ in
                    continuation.yield()
                    continuation.finish()
                }
            }
            try box.process.run()

            async let outputDone: Void = {
                for try await line in stdout.fileHandleForReading.bytes.lines { onOutputLine?(line) }
            }()
            async let log: String = {
                var text = ""
                for try await line in stderr.fileHandleForReading.bytes.lines { text += line + "\n" }
                return text
            }()
            for await _ in finished {}
            try await outputDone
            let collected = try await log
            try Task.checkCancellation()
            return (box.process.terminationStatus, collected)
        } onCancel: {
            box.terminate()
        }
    }
}

/// `Process` isn't Sendable; this wraps the one place it's touched from another task (cancellation).
private nonisolated final class ProcessBox: @unchecked Sendable {
    let process = Process()
    func terminate() { if process.isRunning { process.terminate() } }
}
