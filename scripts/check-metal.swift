import Foundation
import Metal

let shaderURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue() else {
    fatalError("Metal device unavailable")
}
let source = try String(contentsOf: shaderURL, encoding: .utf8)
let library = try device.makeLibrary(source: source, options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "zoneAverage")!)
let textureDescription = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false
)
textureDescription.usage = .shaderRead
let texture = device.makeTexture(descriptor: textureDescription)!
let pixels: [UInt8] = [
    0, 0, 255, 255, 0, 0, 255, 255,
    0, 255, 0, 255, 0, 255, 0, 255
]
pixels.withUnsafeBytes {
    texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: 8)
}
var region = SIMD4<UInt32>(0, 0, 2, 2)
let input = device.makeBuffer(bytes: &region, length: MemoryLayout.size(ofValue: region))!
let output = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride)!
let command = queue.makeCommandBuffer()!
let encoder = command.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline)
encoder.setTexture(texture, index: 0)
encoder.setBuffer(input, offset: 0, index: 0)
encoder.setBuffer(output, offset: 0, index: 1)
encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
encoder.endEncoding()
command.commit()
command.waitUntilCompleted()
guard command.status == .completed else { fatalError("Metal dispatch failed: \(String(describing: command.error))") }
let color = output.contents().load(as: SIMD4<Float>.self)
guard abs(color.x - 0.5) < 0.01, abs(color.y - 0.5) < 0.01, color.z < 0.01 else {
    fatalError("Unexpected zone average: \(color)")
}
print("Metal zone average passed: \(color)")
