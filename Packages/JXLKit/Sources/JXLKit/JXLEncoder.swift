import CJXL
import Foundation

/// Errors thrown while encoding a JPEG XL image.
public enum JXLError: Error, Equatable {
    case invalidDimensions
    case bufferTooSmall
    case encoderCreationFailed
    case libraryError(String)
}

/// Encodes 8-bit sRGB images to JPEG XL using libjxl.
///
/// Each `encode` call creates its own libjxl encoder, so this type holds no
/// shared state and frames can be encoded concurrently.
public struct JXLEncoder: Sendable {
    public struct Options: Sendable, Equatable {
        /// Encode losslessly. When true, `distance` is ignored.
        public var lossless: Bool
        /// Butteraugli distance for lossy encoding (0.0 ... 15.0; 1.0 is visually lossless).
        public var distance: Float
        /// Encoder effort, 1 (fastest) ... 10 (slowest, smallest).
        public var effort: Int

        public init(lossless: Bool = true, distance: Float = 1.0, effort: Int = 3) {
            self.lossless = lossless
            self.distance = distance
            self.effort = effort
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Encodes RGBA8 pixels (alpha is ignored) to a JPEG XL codestream/container.
    /// - Parameters:
    ///   - rgba: Pixel bytes, 4 per pixel, R G B A order.
    ///   - bytesPerRow: Row stride of `rgba`; must be at least `width * 4`.
    public func encode(rgba: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        guard width > 0, height > 0 else { throw JXLError.invalidDimensions }
        guard bytesPerRow >= width * 4, rgba.count >= bytesPerRow * (height - 1) + width * 4 else {
            throw JXLError.bufferTooSmall
        }

        // Repack to tightly packed RGB so no alpha channel is stored.
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        rgb.withUnsafeMutableBufferPointer { dst in
            for y in 0..<height {
                let srcRow = rgba.baseAddress!.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                let dstRow = y * width * 3
                for x in 0..<width {
                    dst[dstRow + x * 3] = srcRow[x * 4]
                    dst[dstRow + x * 3 + 1] = srcRow[x * 4 + 1]
                    dst[dstRow + x * 3 + 2] = srcRow[x * 4 + 2]
                }
            }
        }

        guard let encoder = JxlEncoderCreate(nil) else { throw JXLError.encoderCreationFailed }
        defer { JxlEncoderDestroy(encoder) }

        var info = JxlBasicInfo()
        JxlEncoderInitBasicInfo(&info)
        info.xsize = UInt32(width)
        info.ysize = UInt32(height)
        info.bits_per_sample = 8
        info.exponent_bits_per_sample = 0
        info.num_color_channels = 3
        info.num_extra_channels = 0
        info.alpha_bits = 0
        info.uses_original_profile = options.lossless ? JXL_TRUE : JXL_FALSE
        try check(JxlEncoderSetBasicInfo(encoder, &info), "SetBasicInfo")

        var colorEncoding = JxlColorEncoding()
        JxlColorEncodingSetToSRGB(&colorEncoding, JXL_FALSE)
        try check(JxlEncoderSetColorEncoding(encoder, &colorEncoding), "SetColorEncoding")

        guard let settings = JxlEncoderFrameSettingsCreate(encoder, nil) else {
            throw JXLError.libraryError("FrameSettingsCreate")
        }
        if options.lossless {
            try check(JxlEncoderSetFrameLossless(settings, JXL_TRUE), "SetFrameLossless")
        } else {
            try check(JxlEncoderSetFrameDistance(settings, options.distance), "SetFrameDistance")
        }
        try check(
            JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, Int64(options.effort)),
            "SetEffort"
        )

        var format = JxlPixelFormat(num_channels: 3, data_type: JXL_TYPE_UINT8, endianness: JXL_NATIVE_ENDIAN, align: 0)
        try rgb.withUnsafeBytes { bytes in
            try check(JxlEncoderAddImageFrame(settings, &format, bytes.baseAddress, bytes.count), "AddImageFrame")
        }
        JxlEncoderCloseInput(encoder)

        // Drain the encoder, growing the output buffer as libjxl asks for more room.
        var output = [UInt8](repeating: 0, count: 64 * 1024)
        var written = 0
        while true {
            var status = JXL_ENC_SUCCESS
            output.withUnsafeMutableBufferPointer { buffer in
                var next: UnsafeMutablePointer<UInt8>? = buffer.baseAddress!.advanced(by: written)
                var available = buffer.count - written
                status = JxlEncoderProcessOutput(encoder, &next, &available)
                written = buffer.count - available
            }
            if status == JXL_ENC_NEED_MORE_OUTPUT {
                output.append(contentsOf: [UInt8](repeating: 0, count: output.count))
                continue
            }
            try check(status, "ProcessOutput")
            break
        }
        return Data(output.prefix(written))
    }

    private func check(_ status: JxlEncoderStatus, _ what: String) throws {
        guard status == JXL_ENC_SUCCESS else { throw JXLError.libraryError("\(what) failed (\(status.rawValue))") }
    }
}
