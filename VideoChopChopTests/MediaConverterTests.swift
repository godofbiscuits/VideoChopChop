//
//  MediaConverterTests.swift
//  VideoChopChopTests
//

import AVFoundation
import Foundation
import Testing
@testable import VideoChopChop

private final class FixtureBundleToken {}

private func fixture(_ name: String) throws -> URL {
    let bundle = Bundle(for: FixtureBundleToken.self)
    let url = bundle.url(forResource: name, withExtension: "mkv") ?? bundle.url(forResource: name, withExtension: "mkv", subdirectory: "Fixtures")
    return try #require(url, "fixture \(name).mkv is missing from the test bundle")
}

struct MediaProbeAndPlanTests {
    private let banner = """
    Input #0, matroska,webm, from 'movie.mkv':
      Duration: 01:02:03.50, start: 0.000000, bitrate: 5000 kb/s
      Stream #0:0: Video: h264 (High), yuv420p(progressive), 1920x1080, 24 fps, 24 tbr, 1k tbn (default)
      Stream #0:1(eng): Audio: dts (DTS-HD MA), 48000 Hz, 5.1(side), s32p (default)
      Stream #0:2(eng): Audio: ac3, 48000 Hz, 5.1(side), fltp
      Stream #0:3(eng): Subtitle: subrip
    """

    @Test func parsesCodecsAndDuration() throws {
        let probe = MediaProbe.parse(banner)
        #expect(probe.videoCodec == "h264")
        #expect(probe.audioCodecs == ["dts", "ac3"])
        let duration = try #require(probe.duration)
        #expect(abs(duration - 3723.5) < 0.001)
    }

    @Test func parsesAFileWithNoAudio() {
        let probe = MediaProbe.parse("  Duration: 00:00:10.00, start: 0\n  Stream #0:0: Video: vp9 (Profile 0), yuv420p, 640x360")
        #expect(probe.videoCodec == "vp9")
        #expect(probe.audioCodecs.isEmpty)
    }

    @Test func plansCopyOnlyWhereAppleCanPlayTheCodec() {
        func plan(_ video: String, _ audio: [String]) -> ConversionPlan {
            ConversionPlan(probe: MediaProbe(videoCodec: video, audioCodecs: audio, duration: 1))
        }
        let lossless = plan("h264", ["aac"])
        #expect(lossless.copyVideo && lossless.copyAudio && lossless.isLossless)

        let hevcFlac = plan("hevc", ["flac"])
        #expect(hevcFlac.copyVideo && !hevcFlac.copyAudio && !hevcFlac.isLossless)

        let vp9Opus = plan("vp9", ["opus"])
        #expect(!vp9Opus.copyVideo && !vp9Opus.copyAudio)

        // One un-copyable track forces the audio to be re-encoded; a mix of copyable ones does not.
        #expect(!plan("h264", ["aac", "dts"]).copyAudio)
        #expect(plan("h264", ["aac", "ac3"]).copyAudio)
        #expect(plan("h264", []).copyAudio)
    }

    @Test func buildsTheCommandLine() {
        let input = URL(fileURLWithPath: "/in/movie.mkv"), output = URL(fileURLWithPath: "/out/movie.mp4")
        let hevcCopy = ConversionPlan(probe: MediaProbe(videoCodec: "hevc", audioCodecs: ["aac"], duration: 1)).arguments(input: input, output: output)
        #expect(hevcCopy.contains("copy"))
        #expect(zip(hevcCopy, hevcCopy.dropFirst()).contains { $0 == "-tag:v" && $1 == "hvc1" }, "HEVC copies need the hvc1 tag for AVFoundation")
        #expect(hevcCopy.suffix(1) == ["/out/movie.mp4"])
        #expect(hevcCopy.contains("pipe:1"), "progress is reported on stdout")

        let transcode = ConversionPlan(probe: MediaProbe(videoCodec: "vp9", audioCodecs: ["opus"], duration: 1)).arguments(input: input, output: output)
        #expect(transcode.contains("hevc_videotoolbox") && transcode.contains("aac"))
        // Subtitles and data streams are dropped, only the first video stream is mapped.
        #expect(transcode.contains("-sn") && transcode.contains("0:v:0"))
    }
}

struct MediaConverterTests {
    /// Each test converts into its own folder, so tests running in parallel never touch each other's files.
    private func makeConverter() -> (converter: MediaConverter, cache: URL) {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("converted-\(UUID().uuidString)")
        return (MediaConverter(cacheDirectory: cache), cache)
    }

    @Test func theHelperIsBundledAndExecutable() throws {
        let helper = try #require(MediaConverter.helperURL, "ffmpeg is not in the app bundle: run Scripts/build-ffmpeg.sh and rebuild")
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))
    }

    @Test func aFileAVFoundationCanReadIsNotTouched() async throws {
        let movie = try await makeTestVideo(segments: [.solid(220, 30, 30, frames: 6)])
        defer { try? FileManager.default.removeItem(at: movie) }
        let prepared = try await MediaConverter().prepare(movie)
        #expect(prepared == movie)
    }

    @Test(arguments: [
        ("three-scenes-h264-aac", "lossless rewrap"),
        ("three-scenes-hevc-flac", "video copied, audio re-encoded"),
        ("three-scenes-vp9-opus", "video and audio re-encoded"),
    ])
    func convertsAnMKVToSomethingPlayableWithItsScenesIntact(name: String, kind: String) async throws {
        let (converter, cache) = makeConverter()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mkv = try fixture(name)
        #expect(await !MediaConverter.avFoundationCanRead(mkv), "premise: AVFoundation can't open \(name).mkv itself")

        let progress = ProgressLog()
        let converted = try await converter.prepare(mkv) { progress.add($0) }

        #expect(converted.pathExtension == "mp4", "\(kind)")
        #expect(await MediaConverter.avFoundationCanRead(converted))
        let duration = try await AVURLAsset(url: converted).load(.duration).seconds
        #expect(abs(duration - 3.0) < 0.2, "duration \(duration)")
        #expect(progress.last == 1)

        // The converted video still has its three 1-second scenes (red, blue, green).
        var config = SceneCutConfig()
        config.confirmWithVision = false
        let scenes = try await SceneCutDetector().analyze(url: converted, config: config)
        #expect(scenes.count == 3, "found \(scenes.count) scenes")
        #expect(scenes.count == 3 && abs(scenes[1].startTime - 1.0) < 0.1 && abs(scenes[2].startTime - 2.0) < 0.1)
    }

    @Test func aSecondOpenUsesTheCachedConversion() async throws {
        let (converter, cache) = makeConverter()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mkv = try fixture("three-scenes-h264-aac")
        let first = try await converter.prepare(mkv)
        let modified = try #require(try first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        let second = try await converter.prepare(mkv)
        #expect(second == first)
        #expect(try second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified, "must not be converted again")
    }

    @Test func aFileThatIsNotMediaFailsWithAReadableError() async throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).mkv")
        try Data("this is not a video".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }

        let (converter, cache) = makeConverter()
        defer { try? FileManager.default.removeItem(at: cache) }
        await #expect(throws: ConversionError.self) { try await converter.prepare(junk) }
    }
}

/// Collects progress values reported from the converter's background task.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    var last: Double? { lock.lock(); defer { lock.unlock() }; return values.last }
}
