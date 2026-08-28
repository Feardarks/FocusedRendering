import Metal

/// Compresses a full-resolution image into the rate map's foveated layout.
///
/// The counterpart to `UnwarpShader`. A rasterization rate map can only shape
/// something being rendered, so an image that already exists — a captured screen
/// — has to be resampled into the same layout by hand. Driving that from the
/// map's own decoder rather than reimplementing the falloff keeps the two
/// directions from drifting apart.
public enum WarpShader {

    public struct Uniforms {
        public var screenSize: SIMD2<Float>
        public var physicalSize: SIMD2<Float>

        public init(screenSize: SIMD2<Float>, physicalSize: SIMD2<Float>) {
            self.screenSize = screenSize
            self.physicalSize = physicalSize
        }
    }

    public static let source = """
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

    vertex VertexOut warpVertex(uint vertexID [[vertex_id]]) {
        float2 p = float2(float((vertexID << 1) & 2), float(vertexID & 2));
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    fragment float4 warpFragment(VertexOut in [[stage_in]],
                                 texture2d<float> captured [[texture(0)]],
                                 constant rasterization_rate_map_data &rateData [[buffer(0)]],
                                 constant Uniforms &uniforms [[buffer(1)]]) {
        rasterization_rate_map_decoder decoder(rateData);

        // Each output pixel is a physical sample; ask the map which part of the
        // screen it stands for.
        float2 physicalCoordinates = in.uv * uniforms.physicalSize;
        float2 screenCoordinates =
            decoder.map_physical_to_screen_coordinates(physicalCoordinates, 0);

        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        return captured.sample(linearSampler, screenCoordinates / uniforms.screenSize);
    }
    """

    public static func makePipeline(device: any MTLDevice) throws -> any MTLRenderPipelineState {
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Warp"
        descriptor.vertexFunction = library.makeFunction(name: "warpVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "warpFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
