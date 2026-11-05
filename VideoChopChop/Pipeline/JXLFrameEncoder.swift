//
//  JXLFrameEncoder.swift
//  VideoChopChop
//
//  Compiled only when the JXLKit package is added to the app target
//  (File > Add Package Dependencies > Add Local… > Packages/JXLKit).
//

#if canImport(JXLKit)
import Foundation
import JXLKit

nonisolated struct JXLFrameEncoder: FrameEncoder {
    let settings: JXLSettings
    var fileExtension: String { "jxl" }

    func encode(rgba: [UInt8], width: Int, height: Int) throws -> Data {
        let encoder = JXLEncoder(options: .init(lossless: settings.lossless, distance: settings.distance, effort: settings.effort))
        return try rgba.withUnsafeBytes {
            try encoder.encode(rgba: $0, width: width, height: height, bytesPerRow: width * 4)
        }
    }
}
#endif
