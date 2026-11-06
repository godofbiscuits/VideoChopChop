//
//  OKLab.swift
//  VideoChopChop
//
//  Pixel math for scene-cut detection. All comparisons happen in OKLab:
//  black-to-white distance is about 1.0 and a/b span roughly ±0.4.
//

import Foundation

/// A color in OKLab (L: 0...1, a/b: roughly -0.4...0.4).
nonisolated struct OKLab: Sendable, Equatable {
    var l: Float
    var a: Float
    var b: Float

    /// Euclidean distance (ΔE in OKLab units).
    func distance(to other: OKLab) -> Float {
        let dl = l - other.l, da = a - other.a, db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}

nonisolated enum OKLabMath {
    /// sRGB 8-bit value → linear light, via lookup table.
    private static let linearTable: [Float] = (0..<256).map { value in
        let c = Float(value) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    /// Converts linear-light RGB to OKLab (Björn Ottosson's reference matrices).
    static func fromLinear(r: Float, g: Float, b: Float) -> OKLab {
        let l = cbrtf(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrtf(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrtf(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return OKLab(
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// Converts an 8-bit sRGB pixel to OKLab (sRGB → linear → OKLab).
    static func fromSRGB8(r: UInt8, g: UInt8, b: UInt8) -> OKLab {
        fromLinear(r: linearTable[Int(r)], g: linearTable[Int(g)], b: linearTable[Int(b)])
    }

    /// Converts a tightly or loosely packed RGBA8 (R, G, B, A byte order) buffer to OKLab pixels.
    static func convert(rgba: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> [OKLab] {
        var pixels: [OKLab] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            let row = rgba.baseAddress!.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                pixels.append(fromSRGB8(r: row[x * 4], g: row[x * 4 + 1], b: row[x * 4 + 2]))
            }
        }
        return pixels
    }

    /// Converts linear-light RGBA floats (4 per pixel, as produced by the GPU downscale) to OKLab pixels.
    /// Values are clamped to 0...1 first, since Lanczos ringing can overshoot slightly.
    static func convert(linearRGBA values: [Float], pixelCount: Int) -> [OKLab] {
        (0..<pixelCount).map { i in
            fromLinear(
                r: min(max(values[i * 4], 0), 1), g: min(max(values[i * 4 + 1], 0), 1), b: min(max(values[i * 4 + 2], 0), 1)
            )
        }
    }

    /// Mean per-pixel OKLab distance between two equally sized images.
    static func meanDeltaE(_ lhs: [OKLab], _ rhs: [OKLab]) -> Float {
        precondition(lhs.count == rhs.count, "images must be the same size")
        guard !lhs.isEmpty else { return 0 }
        var total: Float = 0
        for i in lhs.indices { total += lhs[i].distance(to: rhs[i]) }
        return total / Float(lhs.count)
    }
}

/// A normalized 3D OKLab histogram: 8 bins of L over [0, 1], 6 bins each of a and b over [-0.4, 0.4].
nonisolated struct OKLabHistogram: Sendable, Equatable {
    static let lBins = 8
    static let abBins = 6
    static let abRange: Float = 0.4
    static let binCount = lBins * abBins * abBins

    /// Fractions of pixels per bin; sums to 1 for a non-empty image.
    private(set) var bins: [Float]

    /// Pixels are split between the two nearest bins on each axis (trilinear weights), so a small
    /// color drift gives a small histogram change instead of moving every pixel across a bin edge at once.
    init(pixels: [OKLab]) {
        var counts = [Float](repeating: 0, count: Self.binCount)
        for p in pixels {
            let l = Self.softBin(p.l, lower: 0, upper: 1, count: Self.lBins)
            let a = Self.softBin(p.a, lower: -Self.abRange, upper: Self.abRange, count: Self.abBins)
            let b = Self.softBin(p.b, lower: -Self.abRange, upper: Self.abRange, count: Self.abBins)
            for (li, lw) in l { for (ai, aw) in a { for (bi, bw) in b {
                counts[(li * Self.abBins + ai) * Self.abBins + bi] += lw * aw * bw
            } } }
        }
        if !pixels.isEmpty {
            let scale = 1 / Float(pixels.count)
            for i in counts.indices { counts[i] *= scale }
        }
        bins = counts
    }

    /// L1 distance between histograms, 0 (identical) ... 2 (disjoint).
    func l1Distance(to other: OKLabHistogram) -> Float {
        var total: Float = 0
        for i in bins.indices { total += abs(bins[i] - other.bins[i]) }
        return total
    }

    /// The two bins nearest `value` (by bin center) with linear weights that sum to 1; clamps at the edges.
    private static func softBin(_ value: Float, lower: Float, upper: Float, count: Int) -> [(Int, Float)] {
        let position = (value - lower) / (upper - lower) * Float(count) - 0.5
        let clamped = min(max(position, 0), Float(count - 1))
        let low = min(Int(clamped), count - 2)
        let frac = clamped - Float(low)
        return [(low, 1 - frac), (low + 1, frac)]
    }
}
