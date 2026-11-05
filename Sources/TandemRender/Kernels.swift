import CoreImage
import Foundation
import Metal

/// Tandem's own Core Image kernels, written in Metal and compiled once at
/// runtime (`CIKernel.kernels(withMetalString:)`), so the package needs no
/// Metal build step. They run on the shared Metal-backed context.
///
/// All colour work happens on the encoded (gamma) values the way Filmora
/// and most editors do it: the render context has colour management off.
enum Kernels {
    static let header = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    """

    // Each kernel is compiled from its own source. When several stitchable
    // kernels come from one `kernels(withMetalString:)` call, Core Image
    // (macOS 26) runs whichever was used first for all of them.

    static let premultipliedScaleSource = header + """
    extern "C" { namespace coreimage {
    // Multiplies every channel of a premultiplied pixel: layer opacity.
    [[stitchable]] float4 tandemPremultipliedScale(sample_t s, float k) {
        return s * k;
    }
    }}
    """

    static let colorScaleSource = header + """
    extern "C" { namespace coreimage {
    // Multiplies colour but keeps alpha: fades to and from black.
    [[stitchable]] float4 tandemColorScale(sample_t s, float k) {
        return float4(s.rgb * k, s.a);
    }
    }}
    """

    static let colorAdjustSource = header + """
    namespace tandem {
        inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
    }
    extern "C" { namespace coreimage {
    // The Colour effect in one pass. Sliders arrive as -1...1 (exposure in
    // stops): a = (exposure, contrast, black level, highlights),
    // b = (shadows, saturation, vibrance, temperature), c = (tint, 0, 0, 0).
    [[stitchable]] float4 tandemColorAdjust(sample_t s, float4 a, float4 b, float4 c) {
        float alpha = s.a;
        if (alpha <= 0.0) return s;
        float3 x = s.rgb / alpha;
        if (a.x != 0.0) {
            float3 linear = pow(max(x, 0.0), 2.2) * exp2(a.x);
            x = pow(linear, 1.0 / 2.2);
        }
        // Black level 7 lifts shadows by about 2%, as Filmora's does.
        float blackPoint = -a.z * 0.1;
        x = (x - blackPoint) / (1.0 - blackPoint);
        x = (x - 0.5) * (1.0 + a.y * 0.5) + 0.5;
        float l = tandem::luma(x);
        x += a.w * 0.25 * smoothstep(0.5, 1.0, l) + b.x * 0.25 * (1.0 - smoothstep(0.0, 0.5, l));
        l = tandem::luma(x);
        float chroma = clamp(max(max(x.r, x.g), x.b) - min(min(x.r, x.g), x.b), 0.0, 1.0);
        float saturation = (1.0 + b.y) * (1.0 + b.z * (1.0 - chroma));
        x = mix(float3(l), x, saturation);
        x *= float3(1.0 + 0.1 * b.w + 0.05 * c.x, 1.0 - 0.1 * c.x, 1.0 - 0.1 * b.w + 0.05 * c.x);
        x = clamp(x, 0.0, 1.0);
        return float4(x * alpha, alpha);
    }
    }}
    """

    static let hslSource = header + """
    namespace tandem {
        inline float3 rgbToHSL(float3 c) {
            float maxc = max(max(c.r, c.g), c.b);
            float minc = min(min(c.r, c.g), c.b);
            float l = (maxc + minc) * 0.5;
            float d = maxc - minc;
            if (d < 1e-6) { return float3(0.0, 0.0, l); }
            float s = l > 0.5 ? d / (2.0 - maxc - minc) : d / (maxc + minc);
            float h;
            if (maxc == c.r) { h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0); }
            else if (maxc == c.g) { h = (c.b - c.r) / d + 2.0; }
            else { h = (c.r - c.g) / d + 4.0; }
            return float3(h / 6.0, s, l);
        }

        inline float hueToRGB(float p, float q, float t) {
            t = fract(t);
            if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
            if (t < 0.5) return q;
            if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
            return p;
        }

        inline float3 hslToRGB(float3 hsl) {
            if (hsl.y < 1e-6) { return float3(hsl.z); }
            float q = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : hsl.z + hsl.y - hsl.z * hsl.y;
            float p = 2.0 * hsl.z - q;
            return float3(hueToRGB(p, q, hsl.x + 1.0 / 3.0), hueToRGB(p, q, hsl.x), hueToRGB(p, q, hsl.x - 1.0 / 3.0));
        }
    }
    extern "C" { namespace coreimage {
    // Hue, saturation and lightness per colour range: red, orange, yellow,
    // green, aqua, blue, purple, magenta, centred at 0, 30, 60, 120, 180,
    // 240, 270 and 300 degrees. A pixel blends the two ranges its hue sits
    // between, and near-greys are left alone. Values are -1...1.
    [[stitchable]] float4 tandemHSL(sample_t s, float4 h0, float4 h1, float4 s0, float4 s1, float4 l0, float4 l1) {
        float alpha = s.a;
        if (alpha <= 0.0) return s;
        float3 x = clamp(s.rgb / alpha, 0.0, 1.0);
        float3 hsl = tandem::rgbToHSL(x);
        float centres[9] = {0.0, 30.0, 60.0, 120.0, 180.0, 240.0, 270.0, 300.0, 360.0};
        float hues[8] = {h0.x, h0.y, h0.z, h0.w, h1.x, h1.y, h1.z, h1.w};
        float sats[8] = {s0.x, s0.y, s0.z, s0.w, s1.x, s1.y, s1.z, s1.w};
        float lums[8] = {l0.x, l0.y, l0.z, l0.w, l1.x, l1.y, l1.z, l1.w};
        float degrees = hsl.x * 360.0;
        int i = 0;
        for (int k = 1; k < 8; k++) { if (degrees >= centres[k]) { i = k; } }
        int j = (i + 1) % 8;
        float t = clamp((degrees - centres[i]) / (centres[i + 1] - centres[i]), 0.0, 1.0);
        float weight = smoothstep(0.02, 0.2, hsl.y);
        float dh = mix(hues[i], hues[j], t) * weight;
        float ds = mix(sats[i], sats[j], t) * weight;
        float dl = mix(lums[i], lums[j], t) * weight;
        hsl.x = fract(hsl.x + dh * (30.0 / 360.0) + 1.0);
        hsl.y = clamp(hsl.y * (1.0 + ds), 0.0, 1.0);
        hsl.z = clamp(hsl.z + dl * 0.2, 0.0, 1.0);
        x = tandem::hslToRGB(hsl);
        return float4(x * alpha, alpha);
    }
    }}
    """

    static let colorWheelsSource = header + """
    extern "C" { namespace coreimage {
    // The colour wheels as lift, gain and gamma per channel, worked out on
    // the CPU (ColourWheelGrade): x + lift * (1 - x), times gain, then
    // raised to power, odd about zero. Nothing is clamped, so values
    // outside 0...1 (super-whites, extended range) come through finite and
    // in order, and a later effect can still bring them back.
    [[stitchable]] float4 tandemColorWheels(sample_t s, float4 lift, float4 gain, float4 power) {
        float alpha = s.a;
        if (alpha <= 0.0) return s;
        float3 x = s.rgb / alpha;
        x = x + lift.rgb * (1.0 - x);
        x = x * gain.rgb;
        if (any(power.rgb != float3(1.0))) {
            x = sign(x) * pow(abs(x), power.rgb);
        }
        return float4(x * alpha, alpha);
    }
    }}
    """

    static let vignetteSource = header + """
    extern "C" { namespace coreimage {
    // Darkens (amount < 0) or lightens the edges, by a radial mask that is
    // 0 in the clear middle and 1 at full strength.
    [[stitchable]] float4 tandemVignette(sample_t s, sample_t m, float amount) {
        float alpha = s.a;
        if (alpha <= 0.0) return s;
        float t = smoothstep(0.0, 1.0, m.r);
        float3 x = s.rgb / alpha;
        if (amount < 0.0) { x *= 1.0 + amount * t; } else { x += (1.0 - x) * amount * t; }
        return float4(x * alpha, alpha);
    }
    }}
    """

    static let lanczosSource = header + """
    namespace tandem {
        // Lanczos-3: sinc windowed by a wider sinc, zero from 3 pixels out.
        inline float lanczos3(float x) {
            x = fabs(x);
            if (x < 1e-5) return 1.0;
            if (x >= 3.0) return 0.0;
            float px = M_PI_F * x;
            return 3.0 * sin(px) * sin(px / 3.0) / (px * px);
        }
    }
    extern "C" { namespace coreimage {
    // Resamples a layer through an affine transform with Lanczos-3 instead of
    // Core Image's bilinear filter, which goes soft on screen text when a
    // zoom scales the picture up. Each output pixel maps back into the
    // source (r0, r1: the rows of the inverse transform) and mixes the 6x6
    // source pixels around that point. Core Image only hands over the
    // source's own pixels and clamps reads past them to its edge, so
    // anything outside its extent (e: x0, y0, x1, y1) counts as clear here.
    [[stitchable]] float4 tandemLanczos(coreimage::sampler s, float3 r0, float3 r1, float4 e, coreimage::destination dest) {
        float3 d = float3(dest.coord(), 1.0);
        float2 p = float2(dot(r0, d), dot(r1, d));
        // The source pixel centre at or below p, and how far past it p is.
        float2 c = floor(p - 0.5) + 0.5;
        float2 f = p - c;
        float wx[6], wy[6];
        for (int i = 0; i < 6; i++) {
            wx[i] = tandem::lanczos3(f.x - float(i - 2));
            wy[i] = tandem::lanczos3(f.y - float(i - 2));
        }
        float4 sum = float4(0.0);
        float total = 0.0;
        for (int j = 0; j < 6; j++) {
            for (int i = 0; i < 6; i++) {
                float w = wx[i] * wy[j];
                float2 q = c + float2(float(i - 2), float(j - 2));
                if (q.x > e.x && q.x < e.z && q.y > e.y && q.y < e.w) sum += w * s.sample(s.transform(q));
                total += w;
            }
        }
        float4 r = sum / total;
        // The negative lobes overshoot at hard edges. Alpha stays in 0...1;
        // colour is left alone, since the pipeline keeps values past black
        // and white (the colour wheels lean on them).
        r.a = clamp(r.a, 0.0, 1.0);
        // Where nothing's left showing, nothing at all: colour from the
        // lobes under zero alpha would leak into the layers below.
        if (r.a <= 0.0) return float4(0.0);
        return r;
    }
    }}
    """

    static let lanczos: CIKernel? = {
        do {
            return try CIKernel.kernels(withMetalString: lanczosSource).first { $0.name == "tandemLanczos" }
        } catch {
            NSLog("TandemRender: couldn't compile the tandemLanczos kernel: \(error)")
            return nil
        }
    }()

    // MARK: Cutout edge colour
    //
    // The camera's pixels under a soft matte edge are part wall, so a light
    // wall left a pale rim round Mike's cap and shoulders over dark UI. These
    // three give the edge the person's own colour from just inside the
    // outline instead (`FrameComposer.cutoutEdgeColour`).

    /// Where the matte counts as solid person: their colour is taken from
    /// here. Just below 1 so a matte that never quite reaches 1 still has a
    /// core; 0.85 and up is solid on RVM's mattes of Mike.
    static let cutoutCore = (low: Float(0.85), high: Float(0.98))

    static let cutoutCoreSource = header + """
    extern "C" { namespace coreimage {
    // The picture weighted by how solid the matte is there, premultiplied,
    // so a blur of it divided by its alpha is the core's average colour.
    [[stitchable]] float4 tandemCutoutCore(sample_t s, sample_t m, float low, float high) {
        // Times the picture's alpha: outside a crop there's no colour to take.
        float core = smoothstep(low, high, m.r) * s.a;
        float3 c = s.a > 0.0 ? s.rgb / s.a : float3(0.0);
        return float4(c * core, core);
    }
    }}
    """

    static let cutoutFillSource = header + """
    extern "C" { namespace coreimage {
    // The core's colour carried outward: the widest blur's colour where it
    // reaches, then each narrower one over it, so a pixel takes its colour
    // from the nearest part of the person (the black of the cap's rim, not
    // the white logo further in). Out of reach of all of them: the picture.
    inline float3 lay(float3 under, float4 b) {
        if (b.a <= 0.0001) return under;
        return mix(under, b.rgb / b.a, clamp(b.a * 8.0, 0.0, 1.0));
    }
    [[stitchable]] float4 tandemCutoutFill(sample_t s, sample_t b1, sample_t b2, sample_t b3, sample_t b4) {
        float3 c = s.a > 0.0 ? s.rgb / s.a : float3(0.0);
        c = lay(lay(lay(lay(c, b4), b3), b2), b1);
        return float4(c, 1.0);
    }
    }}
    """

    static let cutoutEdgeSource = header + """
    extern "C" { namespace coreimage {
    // The cut-out layer, premultiplied: the picture where the matte is
    // solid, the carried colour where it's soft.
    [[stitchable]] float4 tandemCutoutEdge(sample_t s, sample_t fill, sample_t m, float low, float high) {
        float core = smoothstep(low, high, m.r);
        float3 c = s.a > 0.0 ? s.rgb / s.a : float3(0.0);
        float a = m.r * s.a;
        return float4(mix(fill.rgb, c, core) * a, a);
    }
    }}
    """

    static let cutoutCoreKernel = compile(cutoutCoreSource, "tandemCutoutCore")
    static let cutoutFill = compile(cutoutFillSource, "tandemCutoutFill")
    static let cutoutEdge = compile(cutoutEdgeSource, "tandemCutoutEdge")

    private static func compile(_ source: String, _ name: String) -> CIColorKernel? {
        do {
            return try CIKernel.kernels(withMetalString: source).first { $0.name == name } as? CIColorKernel
        } catch {
            NSLog("TandemRender: couldn't compile the \(name) kernel: \(error)")
            return nil
        }
    }

    static let premultipliedScale = compile(premultipliedScaleSource, "tandemPremultipliedScale")
    static let colorScale = compile(colorScaleSource, "tandemColorScale")
    static let colorAdjust = compile(colorAdjustSource, "tandemColorAdjust")
    static let hsl = compile(hslSource, "tandemHSL")
    static let colorWheels = compile(colorWheelsSource, "tandemColorWheels")
    static let vignette = compile(vignetteSource, "tandemVignette")
}

extension CIImage {
    /// The image through `transform`, resampled with Lanczos-3 (see
    /// `Kernels.lanczosSource`). For scaling up: scaling down this way
    /// would alias, where Core Image's `highQualityDownsample` doesn't.
    /// Falls back to Core Image's own sampling if the kernel isn't there or
    /// the image has no edges to work from.
    func tandemLanczos(_ transform: CGAffineTransform) -> CIImage {
        let source = extent
        guard let kernel = Kernels.lanczos, !source.isInfinite, !source.isEmpty else {
            return transformed(by: transform)
        }
        let inverse = transform.inverted()
        // A few pixels wider than the picture lands: the kernel makes them
        // clear (they read only outside the source), and Core Image repeats
        // a kernel's border pixels past its extent when the frame is bigger,
        // which with the picture's own edge there spread its colour over the
        // whole frame.
        // The filter reaches 3 source pixels, which is that many times the
        // scale in output pixels.
        let scale = max(hypot(transform.a, transform.b), hypot(transform.c, transform.d))
        let margin = (3 * scale).rounded(.up) + 2
        let out = source.applying(transform).integral.insetBy(dx: -margin, dy: -margin)
        // The source pixels an output rectangle reads: its corners mapped
        // back, plus the filter's reach.
        let roi: CIKernelROICallback = { _, rect in rect.applying(inverse).insetBy(dx: -4, dy: -4) }
        let r0 = CIVector(x: inverse.a, y: inverse.c, z: inverse.tx)
        let r1 = CIVector(x: inverse.b, y: inverse.d, z: inverse.ty)
        let edges = CIVector(x: source.minX, y: source.minY, z: source.maxX, w: source.maxY)
        return kernel.apply(extent: out, roiCallback: roi, arguments: [self, r0, r1, edges]) ?? transformed(by: transform)
    }

    /// Multiplies the layer, alpha included: opacity.
    func tandemOpacity(_ opacity: Double) -> CIImage {
        if opacity >= 1 { return self }
        if opacity <= 0 { return CIImage.empty() }
        if let kernel = Kernels.premultipliedScale, let out = kernel.apply(extent: extent, arguments: [self, Float(opacity)]) {
            return out
        }
        return applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(opacity), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(opacity), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(opacity), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        ])
    }

    /// Scales colour towards black, keeping alpha: dips to black.
    func tandemDarkened(_ amount: Double) -> CIImage {
        if amount >= 1 { return self }
        if let kernel = Kernels.colorScale, let out = kernel.apply(extent: extent, arguments: [self, Float(max(amount, 0))]) {
            return out
        }
        return applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(amount), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(amount), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(amount), w: 0)
        ])
    }
}
