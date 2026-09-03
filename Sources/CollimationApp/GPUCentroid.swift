import Foundation
import Metal
import simd

/// GPU copy of `StarDetector.momentCentroid`: peak in a window, then the
/// intensity-weighted center of pixels ≥ 35% of that peak.
///
/// Must run on the **same command queue** as the draw, after this frame’s
/// `replace`, so the reduction sees the texels about to be presented. A second
/// queue raced the previous draw and panned with a one-frame-late centroid.
final class GPUCentroid {
    static let halfWindow = 256

    private let device: MTLDevice
    private let peakPipeline: MTLComputePipelineState
    private let reducePeakPipeline: MTLComputePipelineState
    private let momentPipeline: MTLComputePipelineState
    private let reduceMomentPipeline: MTLComputePipelineState
    private var partials: MTLBuffer?
    private var result: MTLBuffer?
    private var partialCapacity = 0
    private var epoch: UInt32 = 0

    init?(device: MTLDevice) {
        self.device = device
        let options = MTLCompileOptions()
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: options),
              let peak = library.makeFunction(name: "stabilizePeak"),
              let reducePeak = library.makeFunction(name: "stabilizeReducePeak"),
              let moments = library.makeFunction(name: "stabilizeMoments"),
              let reduceMoments = library.makeFunction(name: "stabilizeReduceMoments"),
              let peakPipeline = try? device.makeComputePipelineState(function: peak),
              let reducePeakPipeline = try? device.makeComputePipelineState(function: reducePeak),
              let momentPipeline = try? device.makeComputePipelineState(function: moments),
              let reduceMomentPipeline = try? device.makeComputePipelineState(function: reduceMoments)
        else { return nil }
        self.peakPipeline = peakPipeline
        self.reducePeakPipeline = reducePeakPipeline
        self.momentPipeline = momentPipeline
        self.reduceMomentPipeline = reduceMomentPipeline
        result = device.makeBuffer(length: MemoryLayout<MomentPartial>.stride, options: .storageModeShared)
    }

    func measure(
        queue: MTLCommandQueue,
        texture: MTLTexture,
        seed: SIMD2<Double>?
    ) -> SIMD2<Double>? {
        let width = texture.width
        let height = texture.height
        guard width > 0, height > 0, let result else { return nil }

        let cx = seed.map { Int($0.x.rounded()) } ?? width / 2
        let cy = seed.map { Int($0.y.rounded()) } ?? height / 2
        let hw = max(32, min(Self.halfWindow, max(width, height)))
        let x0 = max(0, cx - hw)
        let y0 = max(0, cy - hw)
        let x1 = min(width, cx + hw + 1)
        let y1 = min(height, cy + hw + 1)
        let roiW = x1 - x0
        let roiH = y1 - y0
        guard roiW > 0, roiH > 0 else { return nil }

        let tgW = 16
        let tgH = 16
        let groupsX = (roiW + tgW - 1) / tgW
        let groupsY = (roiH + tgH - 1) / tgH
        let groupCount = groupsX * groupsY
        guard preparePartials(groupCount: groupCount), let partials else { return nil }

        var roi = StabilizeROI(x0: Int32(x0), y0: Int32(y0), x1: Int32(x1), y1: Int32(y1))
        var groups = UInt32(groupCount)
        epoch &+= 1
        if epoch == 0 { epoch = 1 }
        var epochValue = epoch
        result.contents().assumingMemoryBound(to: MomentPartial.self).pointee = MomentPartial()

        guard let command = queue.makeCommandBuffer() else { return nil }

        let grid = MTLSize(width: groupsX, height: groupsY, depth: 1)
        let threads = MTLSize(width: tgW, height: tgH, depth: 1)
        if let encoder = command.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(peakPipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&roi, length: MemoryLayout<StabilizeROI>.stride, index: 0)
            encoder.setBuffer(partials, offset: 0, index: 1)
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: threads)
            encoder.memoryBarrier(scope: .buffers)

            encoder.setComputePipelineState(reducePeakPipeline)
            encoder.setBuffer(partials, offset: 0, index: 0)
            encoder.setBuffer(result, offset: 0, index: 1)
            encoder.setBytes(&groups, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            encoder.memoryBarrier(scope: .buffers)

            encoder.setComputePipelineState(momentPipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&roi, length: MemoryLayout<StabilizeROI>.stride, index: 0)
            encoder.setBuffer(result, offset: 0, index: 1)
            encoder.setBuffer(partials, offset: 0, index: 2)
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: threads)
            encoder.memoryBarrier(scope: .buffers)

            encoder.setComputePipelineState(reduceMomentPipeline)
            encoder.setBuffer(partials, offset: 0, index: 0)
            encoder.setBuffer(result, offset: 0, index: 1)
            encoder.setBytes(&groups, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.setBytes(&epochValue, length: MemoryLayout<UInt32>.stride, index: 3)
            encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            encoder.endEncoding()
        } else {
            return nil
        }

        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }

        let measured = result.contents().assumingMemoryBound(to: MomentPartial.self).pointee
        guard measured.epoch == epoch, measured.flux > 0 else { return nil }
        return SIMD2(
            Double(measured.sumX) / Double(measured.flux),
            Double(measured.sumY) / Double(measured.flux)
        )
    }

    private func preparePartials(groupCount: Int) -> Bool {
        if partialCapacity >= groupCount, partials != nil { return true }
        let byteCount = max(groupCount, 1) * MemoryLayout<MomentPartial>.stride
        partials = device.makeBuffer(length: byteCount, options: .storageModeShared)
        partialCapacity = groupCount
        return partials != nil
    }

    private struct StabilizeROI {
        var x0: Int32
        var y0: Int32
        var x1: Int32
        var y1: Int32
    }

    private struct MomentPartial {
        var flux: UInt64 = 0
        var sumX: UInt64 = 0
        var sumY: UInt64 = 0
        var peak: UInt32 = 0
        var epoch: UInt32 = 0
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct StabilizeROI {
        int x0;
        int y0;
        int x1;
        int y1;
    };

    struct MomentPartial {
        ulong flux;
        ulong sumX;
        ulong sumY;
        uint peak;
        uint epoch;
    };

    kernel void stabilizePeak(
        texture2d<ushort, access::read> tex [[texture(0)]],
        constant StabilizeROI &roi [[buffer(0)]],
        device MomentPartial *partials [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]],
        uint2 tgid [[threadgroup_position_in_grid]],
        uint2 ntg [[threadgroups_per_grid]],
        uint tid [[thread_index_in_threadgroup]]
    ) {
        threadgroup uint sharedPeak[256];
        uint2 pixel = uint2(uint(roi.x0) + gid.x, uint(roi.y0) + gid.y);
        uint v = 0;
        if (int(pixel.x) < roi.x1 && int(pixel.y) < roi.y1
            && pixel.x < tex.get_width() && pixel.y < tex.get_height()) {
            v = uint(tex.read(pixel).r);
        }
        sharedPeak[tid] = v;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = 128; stride > 0; stride >>= 1) {
            if (tid < stride) {
                sharedPeak[tid] = max(sharedPeak[tid], sharedPeak[tid + stride]);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (tid == 0) {
            uint groupIndex = tgid.y * ntg.x + tgid.x;
            partials[groupIndex].peak = sharedPeak[0];
        }
    }

    kernel void stabilizeReducePeak(
        device const MomentPartial *partials [[buffer(0)]],
        device MomentPartial *result [[buffer(1)]],
        constant uint &groupCount [[buffer(2)]],
        uint tid [[thread_index_in_threadgroup]]
    ) {
        threadgroup uint sharedPeak[256];
        uint v = 0;
        for (uint i = tid; i < groupCount; i += 256) {
            v = max(v, partials[i].peak);
        }
        sharedPeak[tid] = v;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = 128; stride > 0; stride >>= 1) {
            if (tid < stride) {
                sharedPeak[tid] = max(sharedPeak[tid], sharedPeak[tid + stride]);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (tid == 0) {
            result[0].peak = sharedPeak[0];
            result[0].flux = 0;
            result[0].sumX = 0;
            result[0].sumY = 0;
        }
    }

    kernel void stabilizeMoments(
        texture2d<ushort, access::read> tex [[texture(0)]],
        constant StabilizeROI &roi [[buffer(0)]],
        device const MomentPartial *result [[buffer(1)]],
        device MomentPartial *partials [[buffer(2)]],
        uint2 gid [[thread_position_in_grid]],
        uint2 tgid [[threadgroup_position_in_grid]],
        uint2 ntg [[threadgroups_per_grid]],
        uint tid [[thread_index_in_threadgroup]]
    ) {
        threadgroup ulong sharedFlux[256];
        threadgroup ulong sharedX[256];
        threadgroup ulong sharedY[256];
        uint peak = result[0].peak;
        uint threshold = max(uint(1), uint(float(peak) * 0.35));
        ulong flux = 0;
        ulong sumX = 0;
        ulong sumY = 0;
        uint2 pixel = uint2(uint(roi.x0) + gid.x, uint(roi.y0) + gid.y);
        if (peak > 0 && int(pixel.x) < roi.x1 && int(pixel.y) < roi.y1
            && pixel.x < tex.get_width() && pixel.y < tex.get_height()) {
            uint v = uint(tex.read(pixel).r);
            if (v >= threshold) {
                flux = ulong(v);
                sumX = ulong(pixel.x) * ulong(v);
                sumY = ulong(pixel.y) * ulong(v);
            }
        }
        sharedFlux[tid] = flux;
        sharedX[tid] = sumX;
        sharedY[tid] = sumY;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = 128; stride > 0; stride >>= 1) {
            if (tid < stride) {
                sharedFlux[tid] += sharedFlux[tid + stride];
                sharedX[tid] += sharedX[tid + stride];
                sharedY[tid] += sharedY[tid + stride];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (tid == 0) {
            uint groupIndex = tgid.y * ntg.x + tgid.x;
            partials[groupIndex].flux = sharedFlux[0];
            partials[groupIndex].sumX = sharedX[0];
            partials[groupIndex].sumY = sharedY[0];
        }
    }

    kernel void stabilizeReduceMoments(
        device const MomentPartial *partials [[buffer(0)]],
        device MomentPartial *result [[buffer(1)]],
        constant uint &groupCount [[buffer(2)]],
        constant uint &epoch [[buffer(3)]],
        uint tid [[thread_index_in_threadgroup]]
    ) {
        threadgroup ulong sharedFlux[256];
        threadgroup ulong sharedX[256];
        threadgroup ulong sharedY[256];
        ulong flux = 0;
        ulong sumX = 0;
        ulong sumY = 0;
        for (uint i = tid; i < groupCount; i += 256) {
            flux += partials[i].flux;
            sumX += partials[i].sumX;
            sumY += partials[i].sumY;
        }
        sharedFlux[tid] = flux;
        sharedX[tid] = sumX;
        sharedY[tid] = sumY;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = 128; stride > 0; stride >>= 1) {
            if (tid < stride) {
                sharedFlux[tid] += sharedFlux[tid + stride];
                sharedX[tid] += sharedX[tid + stride];
                sharedY[tid] += sharedY[tid + stride];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (tid == 0) {
            result[0].flux = sharedFlux[0];
            result[0].sumX = sharedX[0];
            result[0].sumY = sharedY[0];
            result[0].epoch = epoch;
        }
    }
    """
}
