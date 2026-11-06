//
//  FrameEncoder.swift
//  VideoChopChop
//
//  The exporter encodes frames through this protocol. The JPEG XL implementation lives in
//  JXLFrameEncoder.swift and is compiled in only when the JXLKit package is linked to the app.
//

import Foundation

nonisolated protocol FrameEncoder: Sendable {
    /// File extension, without the dot.
    var fileExtension: String { get }
    /// Encodes tightly packed RGBA8 (R, G, B, A byte order) pixels.
    func encode(rgba: [UInt8], width: Int, height: Int) throws -> Data
}

/// Defaults are lossy: measured on real 854x480 frames, distance 1.5 is ~7.6x smaller than lossless with a
/// mean OKLab error of ~0.009 (well under one just-noticeable difference). Effort above 3 saved almost nothing
/// for 2-3x the encode time.
nonisolated struct JXLSettings: Sendable, Equatable {
    var lossless = false
    var distance: Float = 1.5
    var effort = 3
}

nonisolated enum FrameEncoders {
    /// The JPEG XL encoder, or nil when the JXLKit package isn't linked into this build.
    static func jpegXL(_ settings: JXLSettings) -> (any FrameEncoder)? {
        #if canImport(JXLKit)
        JXLFrameEncoder(settings: settings)
        #else
        nil
        #endif
    }
}
