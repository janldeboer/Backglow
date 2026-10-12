#include <metal_stdlib>
using namespace metal;

// One threadgroup computes one LED region. The CPU only reads the small color buffer.
kernel void zoneAverage(
    texture2d<float, access::read> frame [[texture(0)]],
    device const uint4 *regions [[buffer(0)]],
    device float4 *colors [[buffer(1)]],
    uint zoneIndex [[threadgroup_position_in_grid]],
    uint threadIndex [[thread_index_in_threadgroup]]
) {
    constexpr uint threadsPerZone = 128;
    threadgroup float4 partial[threadsPerZone];
    uint4 region = regions[zoneIndex];
    uint pixelCount = region.z * region.w;
    float4 sum = float4(0.0);
    for (uint offset = threadIndex; offset < pixelCount; offset += threadsPerZone) {
        uint x = region.x + offset % region.z;
        uint y = region.y + offset / region.z;
        sum += frame.read(uint2(x, y));
    }
    partial[threadIndex] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint step = threadsPerZone / 2; step > 0; step /= 2) {
        if (threadIndex < step) {
            partial[threadIndex] += partial[threadIndex + step];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (threadIndex == 0) {
        colors[zoneIndex] = pixelCount == 0 ? float4(0.0) : partial[0] / float(pixelCount);
    }
}
