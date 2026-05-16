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
    int showClipping;   // 0 / 1
};

vertex VertexOut vertex_main(uint vertexID [[vertex_id]],
                              constant Vertex *vertices [[buffer(0)]]) {
    VertexOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.texCoord = vertices[vertexID].texCoord;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                               texture2d<float> baseTex [[texture(0)]],
                               constant FragmentUniforms& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = baseTex.sample(s, in.texCoord);

    if (u.showClipping != 0) {
        float maxc = max(max(c.r, c.g), c.b);
        if (maxc >= 0.99) {
            // Highlight clip → magenta zebra.
            return float4(1.0, 0.0, 1.0, 1.0);
        }
        if (maxc <= 0.02) {
            // Shadow crush → blue zebra.
            return float4(0.0, 0.4, 1.0, 1.0);
        }
    }
    return c;
}
