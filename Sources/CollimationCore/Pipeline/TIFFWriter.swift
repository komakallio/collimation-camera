import Foundation

/// Uncompressed 16-bit grayscale TIFF (little-endian, unsigned, black-is-zero).
public enum MonoTIFF {
    public static func suggestedFileName(width: Int, height: Int, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "collimation-\(width)x\(height)-\(formatter.string(from: date)).tif"
    }

    public static func write(frame: Frame, to url: URL) throws {
        try write(pixels: frame.pixels, width: frame.width, height: frame.height, to: url)
    }

    public static func write(pixels: [UInt16], width: Int, height: Int, to url: URL) throws {
        let data = try encode(pixels: pixels, width: width, height: height)
        try data.write(to: url, options: .atomic)
    }

    public static func encode(pixels: [UInt16], width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, pixels.count == width * height else {
            throw CameraError.unsupported("Frame size \(width)×\(height) does not match \(pixels.count) pixels.")
        }
        let pixelBytes = width * height * 2
        let headerSize = 8
        let ifdCount = 10
        let ifdSize = 2 + ifdCount * 12 + 4
        let stripOffset = UInt32(headerSize)
        let ifdOffset = UInt32(headerSize + pixelBytes)

        var data = Data()
        data.reserveCapacity(headerSize + pixelBytes + ifdSize)
        data.append(contentsOf: [UInt8(ascii: "I"), UInt8(ascii: "I")])
        appendUInt16(&data, 42)
        appendUInt32(&data, ifdOffset)

        pixels.withUnsafeBytes { raw in
            data.append(raw.bindMemory(to: UInt8.self))
        }

        appendUInt16(&data, UInt16(ifdCount))
        appendEntry(&data, tag: 256, type: .long, value: UInt32(width))
        appendEntry(&data, tag: 257, type: .long, value: UInt32(height))
        appendEntry(&data, tag: 258, type: .short, value: 16)
        appendEntry(&data, tag: 259, type: .short, value: 1)
        appendEntry(&data, tag: 262, type: .short, value: 1)
        appendEntry(&data, tag: 273, type: .long, value: stripOffset)
        appendEntry(&data, tag: 277, type: .short, value: 1)
        appendEntry(&data, tag: 278, type: .long, value: UInt32(height))
        appendEntry(&data, tag: 279, type: .long, value: UInt32(pixelBytes))
        appendEntry(&data, tag: 339, type: .short, value: 1)
        appendUInt32(&data, 0)
        return data
    }

    private enum FieldType: UInt16 {
        case short = 3
        case long = 4
    }

    private static func appendEntry(_ data: inout Data, tag: UInt16, type: FieldType, value: UInt32) {
        appendUInt16(&data, tag)
        appendUInt16(&data, type.rawValue)
        appendUInt32(&data, 1)
        if type == .short {
            appendUInt16(&data, UInt16(truncatingIfNeeded: value))
            appendUInt16(&data, 0)
        } else {
            appendUInt32(&data, value)
        }
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
