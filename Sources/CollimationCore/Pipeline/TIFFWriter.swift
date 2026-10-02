import Foundation

/// Uncompressed grayscale TIFF (little-endian, black-is-zero).
public enum MonoTIFF {
    public static func suggestedFileName(
        width: Int,
        height: Int,
        date: Date = Date(),
        label: String? = nil
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let extra = label.map { "-\($0)" } ?? ""
        return "collimation-\(width)x\(height)\(extra)-\(formatter.string(from: date)).tif"
    }

    public static func write(frame: Frame, to url: URL) throws {
        try write(pixels: frame.pixels, width: frame.width, height: frame.height, to: url)
    }

    public static func write(_ image: StackedImage, to url: URL, imageDescription: Data? = nil) throws {
        let data = try encode(floats: image.pixels, width: image.width, height: image.height, imageDescription: imageDescription)
        try data.write(to: url, options: .atomic)
    }

    public static func write(pixels: [UInt16], width: Int, height: Int, to url: URL) throws {
        let data = try encode(pixels: pixels, width: width, height: height)
        try data.write(to: url, options: .atomic)
    }

    public static func write(floats: [Float], width: Int, height: Int, to url: URL) throws {
        let data = try encode(floats: floats, width: width, height: height)
        try data.write(to: url, options: .atomic)
    }

    public static func encode(pixels: [UInt16], width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, pixels.count == width * height else {
            throw CameraError.unsupported("Frame size \(width)×\(height) does not match \(pixels.count) pixels.")
        }
        var strip = Data()
        strip.reserveCapacity(pixels.count * 2)
        pixels.withUnsafeBytes { raw in
            strip.append(raw.bindMemory(to: UInt8.self))
        }
        return encodeStrip(strip, width: width, height: height, bitsPerSample: 16, sampleFormat: 1)
    }

    public static func encode(floats: [Float], width: Int, height: Int, imageDescription: Data? = nil) throws -> Data {
        guard width > 0, height > 0, floats.count == width * height else {
            throw CameraError.unsupported("Frame size \(width)×\(height) does not match \(floats.count) pixels.")
        }
        var strip = Data()
        strip.reserveCapacity(floats.count * 4)
        for value in floats {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { strip.append(contentsOf: $0) }
        }
        var description: Data?
        if let imageDescription {
            guard imageDescription.count <= 256 * 1024, let text = String(data: imageDescription, encoding: .utf8) else {
                throw CameraError.unsupported("Invalid TIFF image description.")
            }
            // JSON Unicode escapes keep TIFF's ASCII tag valid, including
            // camera names and errors containing non-ASCII characters.
            let ascii = text.utf16.map { $0 < 128 ? String(UnicodeScalar($0)!) : String(format: "\\u%04x", Int($0)) }.joined()
            description = Data(ascii.utf8) + Data([0])
            guard description!.count <= 256 * 1024 else { throw CameraError.unsupported("Tilt metadata is too large.") }
        }
        return encodeStrip(strip, width: width, height: height, bitsPerSample: 32, sampleFormat: 3, description: description)
    }

    /// `sampleFormat`: 1 = unsigned integer, 3 = IEEE floating point.
    private static func encodeStrip(
        _ strip: Data,
        width: Int,
        height: Int,
        bitsPerSample: UInt32,
        sampleFormat: UInt32,
        description: Data? = nil
    ) -> Data {
        let pixelBytes = strip.count
        let headerSize = 8
        let ifdCount = description == nil ? 10 : 11
        let stripOffset = UInt32(headerSize)
        let ifdOffset = UInt32(headerSize + pixelBytes)

        var data = Data()
        data.reserveCapacity(headerSize + pixelBytes + 2 + ifdCount * 12 + 4)
        data.append(contentsOf: [UInt8(ascii: "I"), UInt8(ascii: "I")])
        appendUInt16(&data, 42)
        appendUInt32(&data, ifdOffset)
        data.append(strip)

        appendUInt16(&data, UInt16(ifdCount))
        appendEntry(&data, tag: 256, type: .long, value: UInt32(width))
        appendEntry(&data, tag: 257, type: .long, value: UInt32(height))
        appendEntry(&data, tag: 258, type: .short, value: bitsPerSample)
        appendEntry(&data, tag: 259, type: .short, value: 1)
        appendEntry(&data, tag: 262, type: .short, value: 1)
        if let description {
            appendUInt16(&data, 270)
            appendUInt16(&data, 2)
            appendUInt32(&data, UInt32(description.count))
            if description.count <= 4 {
                data.append(description)
                data.append(contentsOf: repeatElement(UInt8(0), count: 4 - description.count))
            } else {
                appendUInt32(&data, ifdOffset + UInt32(2 + ifdCount * 12 + 4))
            }
        }
        appendEntry(&data, tag: 273, type: .long, value: stripOffset)
        appendEntry(&data, tag: 277, type: .short, value: 1)
        appendEntry(&data, tag: 278, type: .long, value: UInt32(height))
        appendEntry(&data, tag: 279, type: .long, value: UInt32(pixelBytes))
        appendEntry(&data, tag: 339, type: .short, value: sampleFormat)
        appendUInt32(&data, 0)
        if let description, description.count > 4 { data.append(description) }
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
