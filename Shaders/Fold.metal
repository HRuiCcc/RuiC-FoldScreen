#include <metal_stdlib>
using namespace metal;

// Uniform layout mirrors FoldUniforms in Swift. Field order, count, and types
// must stay in step: the Swift side hands this struct over with
// setFragmentBytes, so a mismatch silently corrupts every value.
struct FoldUniforms {
    float closure;   // 0 = lid open and untouched, 1 = fully folded
    float kappa;     // perspective depth slope, sin(tilt) / viewDistance
    float maxBlur;   // blur radius in pixels reached at the top edge
    float pinch;     // extra horizontal narrowing at the top edge
    float shade;     // strength of the shading along the sloping sides
    float style;     // preset index: 0 veil, 1 crease, 2 haze
    float aspect;    // drawable width / height, keeps shading bands even
    float pad;       // keeps the struct a multiple of 16 bytes
};

struct FoldVertexOut {
    float4 position [[position]];
    // Hinge-space coordinates: (0,0) is the bottom-left of the display, (0,1)
    // the top-left. Height above the hinge is simply `uv.y`.
    float2 uv;
};

// One oversized triangle covering the viewport. A single triangle avoids the
// diagonal seam a two-triangle quad can show when interpolation is stretched.
vertex FoldVertexOut foldVertex(uint vertexID [[vertex_id]]) {
    float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    float2 corner = corners[vertexID];
    FoldVertexOut out;
    out.position = float4(corner, 0.0, 1.0);
    // Metal's NDC has +y up, and so does hinge space, so this needs no flip.
    out.uv = float2((corner.x + 1.0) * 0.5, (corner.y + 1.0) * 0.5);
    return out;
}

// Picks between the sharp desktop and the four defocus levels.
//
// The levels were blurred once per frame at fixed radii, so a continuously
// varying blur radius is produced by cross-fading neighbours instead of
// re-running a blur per pixel. `radius` is in pixels at the working resolution.
static inline float3 sampleDefocus(
    texture2d<float> sharp, texture2d<float> blurA, texture2d<float> blurB,
    texture2d<float> blurC, texture2d<float> blurD,
    sampler texSampler, float2 uv, float radius)
{
    // Thresholds match the sigma ladder built on the CPU side.
    const float t1 = 5.0;
    const float t2 = 14.0;
    const float t3 = 32.0;
    if (radius <= 0.0) { return sharp.sample(texSampler, uv).rgb; }
    if (radius < t1) {
        return mix(sharp.sample(texSampler, uv).rgb, blurA.sample(texSampler, uv).rgb,
                   smoothstep(0.0, t1, radius));
    }
    if (radius < t2) {
        return mix(blurA.sample(texSampler, uv).rgb, blurB.sample(texSampler, uv).rgb,
                   smoothstep(t1, t2, radius));
    }
    if (radius < t3) {
        return mix(blurB.sample(texSampler, uv).rgb, blurC.sample(texSampler, uv).rgb,
                   smoothstep(t2, t3, radius));
    }
    return mix(blurC.sample(texSampler, uv).rgb, blurD.sample(texSampler, uv).rgb,
               smoothstep(t3, 50.0, radius));
}

fragment float4 foldFragment(
    FoldVertexOut in [[stage_in]],
    texture2d<float> sharp [[texture(0)]],
    texture2d<float> blurA [[texture(1)]],
    texture2d<float> blurB [[texture(2)]],
    texture2d<float> blurC [[texture(3)]],
    texture2d<float> blurD [[texture(4)]],
    constant FoldUniforms &u [[buffer(0)]])
{
    constexpr sampler texSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    float fold = clamp(u.closure, 0.0, 1.0);
    // Height above the hinge: 0 along the bottom edge, 1 at the top edge.
    float dest = in.uv.y;

    // Lid is open: hand the captured desktop through untouched and skip the
    // whole fold, which is the common case while the app sits idle.
    if (fold < 0.002) {
        return float4(sharp.sample(texSampler, float2(in.uv.x, 1.0 - dest)).rgb, 1.0);
    }

    // --- Inverse perspective -------------------------------------------------
    // The display is treated as a plane hinged along its bottom edge, tilted
    // away by an angle that grows with the closure. Projecting a source point at
    // height `s`, then renormalising so both the hinge and the top edge stay
    // pinned, gives the forward map
    //     dest = s * (1 + k) / (1 + s * k)
    // so the upper half of the desktop compresses while the bottom stays put.
    // The shader needs the opposite direction, so invert it for `s`:
    float k = u.kappa;
    float source = dest / (1.0 + k * (1.0 - dest));

    // --- Horizontal narrowing ------------------------------------------------
    // The same tilt makes the plane narrower the further it recedes, so the top
    // pinches in while the hinge keeps the full width. Scaling by `fold` matters:
    // without it the corners would be cut away at full size the instant the lid
    // moved, instead of opening up gradually with the tilt.
    float narrow = 1.0 / (1.0 + u.pinch * fold * source);
    float offset = in.uv.x - 0.5;
    float column = 0.5 + offset / narrow;

    // Textures are top-down while hinge space is bottom-up.
    float2 uv = float2(column, 1.0 - source);

    // --- Coverage ------------------------------------------------------------
    // Past the sloping sides there is no desktop left to show: the display has
    // folded out of view, so fade to the black behind it. Feathering by the
    // screen-space derivative keeps the cut soft at any resolution.
    float feather = max(fwidth(column), 0.002) + 0.012 * fold;
    float edge = 0.5 * narrow - abs(offset);
    float coverage = smoothstep(-feather, feather, edge);

    // --- Defocus -------------------------------------------------------------
    // Blur tracks distance from the viewer, so it is concentrated at the top and
    // leaves the middle of the desktop readable. The cubic keeps the sharp
    // region broad and the falloff near the top edge quick. Scaling by `fold`
    // means the desktop sharpens back up as the lid opens, rather than staying
    // soft and only losing its corners.
    float reach = pow(dest, 3.0);
    float radius = u.maxBlur * fold * reach;

    // Preset character, applied here so the uniforms stay a plain description of
    // the geometry and the presets stay a matter of look rather than layout.
    float blurScale = 1.0;
    float pinchScale = 1.0;
    float shadeScale = 1.0;
    bool frosted = false;
    if (u.style > 1.5) {
        blurScale = 1.35; pinchScale = 0.78; shadeScale = 0.7; frosted = true;
    } else if (u.style > 0.5) {
        blurScale = 0.85; pinchScale = 1.35; shadeScale = 1.8;
    }
    radius *= blurScale;

    float3 color = sampleDefocus(sharp, blurA, blurB, blurC, blurD, texSampler, uv, radius);

    if (frosted) {
        // A cool lift, as if the folded panel were catching ambient light.
        color = mix(color, float3(0.88, 0.92, 0.97), fold * pow(dest, 2.0) * 0.12);
    }

    // --- Shading -------------------------------------------------------------
    // The sloping sides turn away from the viewer, so they darken. Scaled by the
    // aspect ratio to keep the band a constant thickness on any display shape.
    float band = max(edge, 0.0) * u.aspect;
    color *= 1.0 - exp(-band / 0.055) * u.shade * shadeScale * fold;

    // A gentle overall deepening toward the top sells the fold as one surface
    // rather than a flat image with its corners cut off.
    color *= 1.0 - 0.22 * fold * pow(dest, 2.4);

    return float4(color * coverage, 1.0);
}
