import Metal

/// A deliberately fragment-bound scene carrying high-frequency detail.
///
/// Foveated rendering only pays for itself where per-pixel work dominates, so
/// the benchmark uses a raymarched signed-distance scene: almost all of its cost
/// is in the fragment shader and scales with the pixels actually rasterized.
/// `marchSteps` is the cost dial.
///
/// Surfaces carry a fine procedural pattern on purpose. A scene of smooth
/// gradients survives undersampling nearly intact, which flatters the
/// reconstruction and would report a quality figure no real content could
/// match.
///
/// The march exits early when it hits a surface, as a real renderer would. That
/// keeps divergence in the measurement rather than making saved time a trivial
/// restatement of saved pixels.
public enum HeavyScene {

    public struct Uniforms {
        public var time: Float
        public var marchSteps: UInt32
        public init(time: Float, marchSteps: UInt32) {
            self.time = time
            self.marchSteps = marchSteps
        }
    }

    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float time;
        uint  marchSteps;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut heavyVertex(uint vertexID [[vertex_id]]) {
        float2 p = float2(float((vertexID << 1) & 2), float(vertexID & 2));
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = p;
        return out;
    }

    static float sdSphere(float3 p, float r) {
        return length(p) - r;
    }

    static float sdBox(float3 p, float3 b) {
        float3 q = abs(p) - b;
        return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
    }

    static float sceneDistance(float3 p, float time) {
        float d = p.y + 1.6;
        d = min(d, sdSphere(p - float3(sin(time) * 1.4, 0.0, 0.0), 1.0));
        d = min(d, sdBox(p - float3(-2.2, sin(time * 0.7) * 0.5, 1.0), float3(0.7)));
        float3 q = fract(p * 0.22) - 0.5;
        d = min(d, sdSphere(q * 4.5, 1.05) * 0.22);
        return d;
    }

    static float3 sceneNormal(float3 p, float time) {
        const float e = 0.0015;
        float2 k = float2(1.0, -1.0);
        return normalize(k.xyy * sceneDistance(p + k.xyy * e, time) +
                         k.yyx * sceneDistance(p + k.yyx * e, time) +
                         k.yxy * sceneDistance(p + k.yxy * e, time) +
                         k.xxx * sceneDistance(p + k.xxx * e, time));
    }

    static float softShadow(float3 origin, float3 direction, float time, uint steps) {
        float result = 1.0;
        float t = 0.05;
        for (uint i = 0; i < steps; ++i) {
            float h = sceneDistance(origin + direction * t, time);
            if (h < 0.001) { return 0.0; }
            result = min(result, 12.0 * h / t);
            t += clamp(h, 0.02, 0.4);
            if (t > 20.0) { break; }
        }
        return clamp(result, 0.0, 1.0);
    }

    static float ambientOcclusion(float3 p, float3 n, float time) {
        float occlusion = 0.0;
        float weight = 1.0;
        for (int i = 0; i < 6; ++i) {
            float h = 0.02 + 0.12 * float(i);
            occlusion += (h - sceneDistance(p + n * h, time)) * weight;
            weight *= 0.72;
        }
        return clamp(1.0 - 1.6 * occlusion, 0.0, 1.0);
    }

    fragment float4 heavyFragment(VertexOut in [[stage_in]],
                                  constant Uniforms &uniforms [[buffer(0)]]) {
        float2 uv = in.uv * 2.0 - 1.0;
        float3 origin = float3(0.0, 0.6, -5.0);
        float3 direction = normalize(float3(uv.x * 1.2, uv.y * 1.2, 1.8));

        float t = 0.0;
        bool hit = false;
        for (uint i = 0; i < uniforms.marchSteps; ++i) {
            float d = sceneDistance(origin + direction * t, uniforms.time);
            if (d < 0.0015) { hit = true; break; }
            t += d;
            if (t > 40.0) { break; }
        }

        float3 colour = float3(0.03, 0.04, 0.06);
        if (hit) {
            float3 p = origin + direction * t;
            float3 n = sceneNormal(p, uniforms.time);
            float ao = ambientOcclusion(p, n, uniforms.time);

            float3 lightDirections[3];
            lightDirections[0] = normalize(float3( 0.6, 0.8, -0.4));
            lightDirections[1] = normalize(float3(-0.7, 0.5,  0.3));
            lightDirections[2] = normalize(float3( 0.1, 0.9,  0.6));

            float3 lightColours[3];
            lightColours[0] = float3(1.00, 0.92, 0.80);
            lightColours[1] = float3(0.35, 0.48, 0.90);
            lightColours[2] = float3(0.90, 0.40, 0.55);

            float3 lit = float3(0.0);
            for (int i = 0; i < 3; ++i) {
                float diffuse = max(dot(n, lightDirections[i]), 0.0);
                float shadow = softShadow(p + n * 0.01, lightDirections[i],
                                          uniforms.time, uniforms.marchSteps / 2);
                float3 halfway = normalize(lightDirections[i] - direction);
                float specular = pow(max(dot(n, halfway), 0.0), 48.0);
                lit += lightColours[i] * (diffuse * shadow + specular * shadow * 0.6);
            }
            // High-frequency surface detail. Without it the periphery is all
            // smooth gradients, which survive undersampling almost intact and
            // make the reconstruction look far better than real content with
            // textures and fine geometry ever would.
            float detail = sin(p.x * 38.0) * sin(p.y * 38.0) * sin(p.z * 38.0);
            float albedo = mix(0.32, 1.0, 0.5 + 0.5 * detail);
            colour = lit * ao * albedo;
        }

        colour = pow(max(colour, float3(0.0)), float3(1.0 / 2.2));
        return float4(colour, 1.0);
    }
    """

    public static func makePipeline(device: any MTLDevice) throws -> any MTLRenderPipelineState {
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "HeavyScene"
        descriptor.vertexFunction = library.makeFunction(name: "heavyVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "heavyFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
