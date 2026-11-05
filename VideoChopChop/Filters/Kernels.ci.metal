//
//  Kernels.ci.metal
//  VideoChopChop
//
//  Core Image color kernels, precompiled into default.metallib.
//  Requires the target build settings MTL_COMPILER_FLAGS = -fcikernel and MTLLINKER_FLAGS = -cikernel
//  (see Metal.xcconfig). Do not mark kernels [[stitchable]]: that attribute is for runtime-compiled
//  kernels, and on a precompiled library it stops the function being registered as a Core Image kernel.
//

#include <CoreImage/CoreImage.h>

extern "C" { namespace coreimage {

    // Scales chroma and lightness in OKLab. Core Image's working space is linear light,
    // so the input is already linear and goes straight into the OKLab transform.
    float4 oklabTweak(sample_t s, float saturation, float lightness) {
        float4 u = unpremultiply(s);
        float3 c = u.rgb;

        float l = pow(max(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b, 0.0), 1.0 / 3.0);
        float m = pow(max(0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b, 0.0), 1.0 / 3.0);
        float n = pow(max(0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b, 0.0), 1.0 / 3.0);

        float L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * n;
        float a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * n;
        float b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * n;

        L = clamp(L * lightness, 0.0, 1.0);
        a *= saturation;
        b *= saturation;

        float l_ = L + 0.3963377774 * a + 0.2158037573 * b;
        float m_ = L - 0.1055613458 * a - 0.0638541728 * b;
        float n_ = L - 0.0894841775 * a - 1.2914855480 * b;
        l_ = l_ * l_ * l_;
        m_ = m_ * m_ * m_;
        n_ = n_ * n_ * n_;

        float3 rgb = float3(
             4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * n_,
            -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * n_,
            -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * n_);

        return premultiply(float4(clamp(rgb, 0.0, 1.0), u.a));
    }

} }
