import Metal

/// Inverts the rasterization rate map, turning a foveated render back into a
/// normal image.
///
/// The physical texture stores the periphery at reduced density, so undoing it
/// means asking the map where each screen pixel's samples actually live. Metal
/// exposes that inside a shader through `rasterization_rate_map_decoder`, fed by
/// the parameter buffer the map hands out — reimplementing the mapping from the
/// profile's falloff would be a second, drifting source of truth.
enum UnwarpShader {

    struct Uniforms {
        var screenSize: SIMD2<Float>
        var physicalSize: SIMD2<Float>
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 screenSize;
        float2 physicalSize;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut unwarpVertex(uint vertexID [[vertex_id]]) {
        float2 p = float2(float((vertexID << 1) & 2), float(vertexID & 2));
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        // Flip vertically: NDC counts up, texture rows count down.
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    fragment float4 unwarpFragment(VertexOut in [[stage_in]],
                                   texture2d<float> foveated [[texture(0)]],
                                   constant rasterization_rate_map_data &rateData [[buffer(0)]],
                                   constant Uniforms &uniforms [[buffer(1)]]) {
        rasterization_rate_map_decoder decoder(rateData);

        float2 screenCoordinates = in.uv * uniforms.screenSize;
        float2 physicalCoordinates =
            decoder.map_screen_to_physical_coordinates(screenCoordinates, 0);

        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        return foveated.sample(linearSampler, physicalCoordinates / uniforms.physicalSize);
    }
    """

    static func makePipeline(device: any MTLDevice) throws -> any MTLRenderPipelineState {
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Unwarp"
        descriptor.vertexFunction = library.makeFunction(name: "unwarpVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "unwarpFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
