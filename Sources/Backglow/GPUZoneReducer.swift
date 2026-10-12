import BackglowCore
import CoreVideo
import Metal

final class GPUZoneReducer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let shaderURL = Bundle.module.url(forResource: "ZoneAverage", withExtension: "metal"),
              let shader = try? String(contentsOf: shaderURL, encoding: .utf8),
              let library = try? device.makeLibrary(source: shader, options: nil),
              let function = library.makeFunction(name: "zoneAverage"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard textureCache != nil else { return nil }
    }

    func reduce(
        pixelBuffer: CVPixelBuffer,
        zones: [LightingZone],
        completion: @escaping ([LightingRGB]?) -> Void
    ) -> Bool {
        guard !zones.isEmpty, let textureCache else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        // The sRGB view makes the GPU linearize every sample, so zones average light, not code values.
        var textureReference: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm_srgb, width, height, 0, &textureReference
        )
        guard status == kCVReturnSuccess,
              let textureReference,
              let texture = CVMetalTextureGetTexture(textureReference) else { return false }

        let rectangles = zones.map {
            SIMD4<UInt32>(UInt32($0.rect.x), UInt32($0.rect.y),
                          UInt32($0.rect.width), UInt32($0.rect.height))
        }
        let rectangleBytes = rectangles.count * MemoryLayout<SIMD4<UInt32>>.stride
        let outputBytes = zones.count * MemoryLayout<SIMD4<Float>>.stride
        guard let regionBuffer = rectangles.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: rectangleBytes, options: .storageModeShared)
        }),
        let colorBuffer = device.makeBuffer(length: outputBytes, options: .storageModeShared),
        let commandBuffer = queue.makeCommandBuffer(),
        let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(regionBuffer, offset: 0, index: 0)
        encoder.setBuffer(colorBuffer, offset: 0, index: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: zones.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { buffer in
            _ = textureReference // Keep the IOSurface-backed texture alive through completion.
            guard buffer.status == .completed else {
                completion(nil)
                return
            }
            let pointer = colorBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: zones.count)
            let colors = (0..<zones.count).map { index in
                let value = pointer[index]
                return LightingRGB(red: Double(value.x), green: Double(value.y), blue: Double(value.z))
            }
            completion(colors)
        }
        commandBuffer.commit()
        return true
    }
}
