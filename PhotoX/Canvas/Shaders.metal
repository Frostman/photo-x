#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 position;
    float2 texCoord;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct FragmentUniforms {
    int showClipping;       // 0 / 1
    int showPeaking;        // 0 / 1
    float peakingThreshold; // 0..1 (typ. 0.15)
};

vertex VertexOut vertex_main(uint vertexID [[vertex_id]],
                              constant Vertex *vertices [[buffer(0)]]) {
    VertexOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.texCoord = vertices[vertexID].texCoord;
    return out;
}

static inline float luma(float3 rgb) {
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                               texture2d<float> baseTex [[texture(0)]],
                               constant FragmentUniforms& u [[buffer(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float4 c = baseTex.sample(smp, in.texCoord);

    if (u.showClipping != 0) {
        float maxc = max(max(c.r, c.g), c.b);
        if (maxc >= 0.99) {
            return float4(1.0, 0.0, 1.0, 1.0);
        }
        if (maxc <= 0.02) {
            return float4(0.0, 0.4, 1.0, 1.0);
        }
    }

    if (u.showPeaking != 0) {
        // Sobel on luminance, sampling 8 neighbors at the source texel spacing.
        float2 ts = 1.0 / float2(baseTex.get_width(), baseTex.get_height());
        float tl = luma(baseTex.sample(smp, in.texCoord + ts * float2(-1, -1)).rgb);
        float t  = luma(baseTex.sample(smp, in.texCoord + ts * float2( 0, -1)).rgb);
        float tr = luma(baseTex.sample(smp, in.texCoord + ts * float2( 1, -1)).rgb);
        float l  = luma(baseTex.sample(smp, in.texCoord + ts * float2(-1,  0)).rgb);
        float r  = luma(baseTex.sample(smp, in.texCoord + ts * float2( 1,  0)).rgb);
        float bl = luma(baseTex.sample(smp, in.texCoord + ts * float2(-1,  1)).rgb);
        float b  = luma(baseTex.sample(smp, in.texCoord + ts * float2( 0,  1)).rgb);
        float br = luma(baseTex.sample(smp, in.texCoord + ts * float2( 1,  1)).rgb);
        float gx = -tl - 2.0 * l - bl + tr + 2.0 * r + br;
        float gy = -tl - 2.0 * t - tr + bl + 2.0 * b + br;
        float edge = sqrt(gx * gx + gy * gy);
        if (edge > u.peakingThreshold) {
            float strength = clamp((edge - u.peakingThreshold) * 4.0, 0.0, 0.9);
            float3 peakCol = float3(1.0, 0.13, 0.0);
            return float4(mix(c.rgb, peakCol, strength), 1.0);
        }
    }

    return c;
}
