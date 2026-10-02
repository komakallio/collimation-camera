import Foundation

extension MonoTIFF {
    /// Read the single-strip float format written by Save Constellation.
    public static func readConstellation(from url: URL) throws -> StackedImage {
        try readConstellationWithMetadata(from: url).image
    }

    public static func readConstellationWithMetadata(from url: URL) throws -> (image: StackedImage, report: TiltMeasurementReport?, warning: String?) {
        let limit = 4 * 1024 * 1024
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit {
            throw CameraError.unsupported("Constellation TIFF is too large; expected a 768×768 float mosaic.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let image = try decodeConstellation(data)
        let metadata = decodeTiltMetadata(data)
        return (image, metadata.report, metadata.warning)
    }

    /// Metadata failure never hides an otherwise valid constellation image.
    public static func decodeTiltMetadata(_ data: Data) -> (report: TiltMeasurementReport?, warning: String?) {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> UInt16? {
            guard offset >= 0, offset <= bytes.count - 2 else { return nil }
            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset <= bytes.count - 4 else { return nil }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        let invalid = "Tilt metadata could not be read; the constellation image is still available."
        guard let rawIFD = u32(4) else { return (nil, nil) }
        let ifd = Int(rawIFD)
        guard let count = u16(ifd), count <= 64 else { return (nil, nil) }
        var description: Data?
        for i in 0..<Int(count) {
            let at = ifd + 2 + i * 12
            guard u16(at) == 270 else { continue }
            guard description == nil, u16(at + 2) == 2, let size = u32(at + 4), size > 0, size <= 256 * 1024,
                  let rawOffset = u32(at + 8) else { return (nil, invalid) }
            let start = size <= 4 ? at + 8 : Int(rawOffset)
            guard start >= 8, start <= bytes.count - Int(size), bytes[start + Int(size) - 1] == 0 else { return (nil, invalid) }
            description = Data(bytes[start..<(start + Int(size) - 1)])
        }
        guard let description else { return (nil, nil) }
        do { return (try TiltMeasurementReport.decode(description), nil) }
        catch { return (nil, "Tilt metadata unavailable: \(error.localizedDescription)") }
    }

    public static func decodeConstellation(_ data: Data) throws -> StackedImage {
        let unsupported = CameraError.unsupported("Open an uncompressed 768×768, 32-bit float mono constellation TIFF saved by this app.")
        guard data.count >= 8, data.count <= 4 * 1024 * 1024 else { throw unsupported }
        let bytes = [UInt8](data)
        func u16(_ offset: Int) throws -> UInt16 {
            guard offset >= 0, offset <= bytes.count - 2 else { throw unsupported }
            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= bytes.count - 4 else { throw unsupported }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        guard bytes[0] == 73, bytes[1] == 73, try u16(2) == 42 else { throw unsupported }
        let ifd = Int(try u32(4))
        guard ifd >= 8 else { throw unsupported }
        let count = Int(try u16(ifd))
        guard count <= 64, ifd + 2 + count * 12 + 4 <= bytes.count else { throw unsupported }
        let known: Set<UInt16> = [256, 257, 258, 259, 262, 273, 274, 277, 278, 279, 284, 339]
        var tags: [UInt16: UInt32] = [:]
        for i in 0..<count {
            let at = ifd + 2 + i * 12
            let tag = try u16(at)
            guard known.contains(tag) else { continue }
            let type = try u16(at + 2)
            guard tags[tag] == nil, try u32(at + 4) == 1, type == 3 || type == 4 else { throw unsupported }
            tags[tag] = type == 3 ? UInt32(try u16(at + 8)) : try u32(at + 8)
        }
        let side = CaptureLayout.stackingCropSize * 3
        let byteCount = side * side * 4
        guard tags[256] == UInt32(side), tags[257] == UInt32(side), tags[258] == 32,
              tags[259] == 1, tags[262] == 1, tags[339] == 3,
              (tags[277] ?? 1) == 1, (tags[274] ?? 1) == 1, (tags[284] ?? 1) == 1,
              let rows = tags[278], rows >= UInt32(side), tags[279] == UInt32(byteCount),
              let strip = tags[273], try u32(ifd + 2 + count * 12) == 0 else { throw unsupported }
        let start = Int(strip)
        guard start >= 8, start <= bytes.count - byteCount,
              start + byteCount <= ifd || start >= ifd + 2 + count * 12 + 4 else { throw unsupported }
        var pixels = [Float]()
        pixels.reserveCapacity(side * side)
        for i in 0..<(side * side) {
            let value = Float(bitPattern: try u32(start + i * 4))
            // Float accumulation can put a saturated mean slightly over 65535.
            guard value.isFinite, value >= 0 else {
                throw CameraError.unsupported("Constellation TIFF contains invalid pixel values.")
            }
            pixels.append(value)
        }
        return StackedImage(width: side, height: side, pixels: pixels, roi: ROI(x: 0, y: 0, width: side, height: side))
    }
}
